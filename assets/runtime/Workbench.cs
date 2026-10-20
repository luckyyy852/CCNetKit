using System;
using System.IO;
using System.Text;
using System.Net;
using System.Linq;
using System.Diagnostics;
using System.Drawing;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Threading.Tasks;
using System.Runtime.InteropServices;

static class Program {
    internal static readonly string Root=Path.GetFullPath(Environment.GetEnvironmentVariable("NETWORK_WORKBENCH_HOME")??Path.Combine(AppDomain.CurrentDomain.BaseDirectory,".."));
    internal static object Val(object obj,string key){object value;var dict=obj as Dictionary<string,object>;return dict!=null&&dict.TryGetValue(key,out value)?value:null;}
    internal static string Str(object obj,string key){return Convert.ToString(Val(obj,key));}
    internal static long Num(object obj,string key){long n;return Int64.TryParse(Str(obj,key),out n)?n:0;}
    internal static bool Flag(object obj,string key){return Val(obj,key) is bool&&(bool)Val(obj,key);}
    internal static object ReadFile(string path){return new JavaScriptSerializer(){MaxJsonLength=16*1024*1024}.DeserializeObject(File.ReadAllText(path,Encoding.UTF8));}
    internal static object Settings {get{return ReadFile(Path.Combine(Root,"settings.json"));}}
    internal static object[] Profiles {get{return Val(Settings,"Profiles") as object[]??new object[0];}}
    internal static object Api(object profile,string endpoint) {
        var cfg=ReadFile(Str(profile,"ConfigPath"));Uri uri;
        if(!Uri.TryCreate("http://"+Str(cfg,"external-controller"),UriKind.Absolute,out uri)||!uri.IsLoopback||uri.Port<1||uri.UserInfo.Length>0||uri.AbsolutePath!="/"||uri.Query.Length>0||uri.Fragment.Length>0)throw new Exception("控制 API 必须仅监听本机回环地址。");
        var r=(HttpWebRequest)WebRequest.Create(new Uri(uri,endpoint));r.Proxy=null;r.AllowAutoRedirect=false;r.Method="GET";r.Timeout=2000;r.ReadWriteTimeout=2000;
        r.Headers["Authorization"]="Bearer "+Str(cfg,"secret");
        using(var response=r.GetResponse())using(var reader=new StreamReader(response.GetResponseStream()))return new JavaScriptSerializer(){MaxJsonLength=16*1024*1024}.DeserializeObject(reader.ReadToEnd());
    }
    internal static string Size(double number){string[] units={"B","KB","MB","GB","TB"};int i=0;while(number>=1024&&i<4){number/=1024;i++;}return number.ToString(i==0?"0":"0.0")+" "+units[i];}
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr handle,uint flags,StringBuilder path,ref int size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr handle,out long created,out long exited,out long kernel,out long user);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    internal static bool MatchProcess(object record) {
        IntPtr handle=IntPtr.Zero;
        try {
            DateTime expected;if(!DateTime.TryParse(Str(record,"startTimeUtc"),out expected))return false;
            handle=OpenProcess(0x1000,false,(int)Num(record,"pid"));if(handle==IntPtr.Zero)return false;
            long created,exited,kernel,user;var path=new StringBuilder(32768);int size=path.Capacity;
            return GetProcessTimes(handle,out created,out exited,out kernel,out user) &&
                QueryFullProcessImageName(handle,0,path,ref size) &&
                DateTime.FromFileTimeUtc(created).Ticks==expected.ToUniversalTime().Ticks &&
                String.Equals(path.ToString(),Str(record,"executable"),StringComparison.OrdinalIgnoreCase);
        }catch{return false;}finally{if(handle!=IntPtr.Zero)CloseHandle(handle);}
    }
    [DllImport("iphlpapi.dll", SetLastError=true)]
    static extern uint GetExtendedTcpTable(IntPtr table,ref int size,bool order,int family,int tableClass,uint reserved);
    internal static Dictionary<int,string> ProcessNames() {
        var names=new Dictionary<int,string>();var cache=new Dictionary<int,string>();
        foreach(int family in new[]{2,23}) {
            int size=0;GetExtendedTcpTable(IntPtr.Zero,ref size,false,family,5,0);if(size<4)continue;
            IntPtr buffer=Marshal.AllocHGlobal(size);
            try {
                if(GetExtendedTcpTable(buffer,ref size,false,family,5,0)!=0)continue;
                int count=Marshal.ReadInt32(buffer),stride=family==2?24:56;
                for(int i=0;i<count;i++) {
                    int offset=4+i*stride,portOffset=offset+(family==2?8:20);
                    int port=Marshal.ReadByte(buffer,portOffset)*256+Marshal.ReadByte(buffer,portOffset+1);
                    int pid=Marshal.ReadInt32(buffer,offset+(family==2?20:52));if(pid==0)continue;
                    string name;
                    if(!cache.TryGetValue(pid,out name)) {
                        try {using(var p=Process.GetProcessById(pid))name=p.ProcessName+".exe";} catch {name="未识别";}
                        cache[pid]=name;
                    }
                    names[port]=name;
                }
            } finally {Marshal.FreeHGlobal(buffer);}
        }
        return names;
    }
    internal static string ProtectionStatus() {
        var settings=Val(Settings,"Protection");
        if(settings==null||String.IsNullOrWhiteSpace(Str(settings,"GuardStatePath")))return "专用保护：未接入状态（本工具不替代防直连隔离）";
        try {
            var state=ReadFile(Str(settings,"GuardStatePath"));
            bool locked=Flag(state,"latched")||(!String.IsNullOrEmpty(Str(settings,"LockPath"))&&File.Exists(Str(settings,"LockPath")));
            if(locked)return "专用保护：已锁定，请使用原有的手动恢复入口";
            return MatchProcess(state)&&Flag(state,"armed")?"专用保护：守卫运行中（仅核验已有守卫状态）":"专用保护：守卫未就绪，不能确认受保护";
        }catch{return "专用保护：状态不可读，不能确认受保护";}
    }
    internal static Snapshot Load() {
        var s=new Snapshot(){At=DateTime.Now};var visited=new HashSet<string>();var processNames=ProcessNames();
        foreach(var profile in Profiles) {
            if(Val(profile,"Reload") is bool&&!Flag(profile,"Reload"))continue;
            string name=Str(profile,"Name");
            try {
                string cfgPath=Str(profile,"ConfigPath");var cfg=ReadFile(cfgPath);string key=Str(cfg,"external-controller");
                if(!visited.Add(key))continue;
                var general=Api(profile,"/configs");var traffic=Api(profile,"/connections");
                s.Cores++;s.Tun|=Flag(Val(general,"tun"),"enable");s.Download+=Num(traffic,"downloadTotal");s.Upload+=Num(traffic,"uploadTotal");
                foreach(var row in Val(traffic,"connections") as object[]??new object[0]) {
                    var m=Val(row,"metadata");var chains=(Val(row,"chains") as object[]??new object[0]).Select(Convert.ToString).ToArray();
                    string route=chains.Contains("DIRECT")?"直连":chains.Any(c=>c.StartsWith("REJECT"))?"已拦截":"代理线路";
                    if(route=="直连")s.Direct++;else if(route=="代理线路")s.Proxy++;
                    string process=Str(m,"process");if(process.Length==0)process=Path.GetFileName(Str(m,"processPath"));if(process.Length==0&&Str(m,"network")=="tcp")processNames.TryGetValue((int)Num(m,"sourcePort"),out process);if(String.IsNullOrEmpty(process))process="未识别";
                    string host=Str(m,"host");if(host.Length==0)host=Str(m,"destinationIP");
                    s.Rows.Add(new[]{process,host+":"+Str(m,"destinationPort"),route,Str(m,"network").ToUpperInvariant(),Size(Num(row,"download")),Size(Num(row,"upload")),"连接中",key+":"+Str(row,"id")});
                }
                var rules=Val(Api(profile,"/rules"),"rules") as object[]??new object[0];
                foreach(var rule in rules) {
                    string type=Str(rule,"type");if(type!="Domain"&&type!="DomainSuffix")continue;
                    string policy=Str(rule,"proxy");string route=policy=="DIRECT"?"直连":policy.StartsWith("REJECT")?"已拦截":"代理线路";
                    var extra=Val(rule,"extra");long hits=Num(extra,"hitCount");DateTimeOffset hitAt;
                    string state=hits>0?"命中 "+hits+" 次":"已配置，尚无命中";
                    if(hits>0&&DateTimeOffset.TryParse(Str(extra,"hitAt"),out hitAt))state+=" · "+hitAt.ToLocalTime().ToString("HH:mm:ss");
                    s.RuleRows.Add(new[]{(hits>0?"规则命中":"规则设置")+"（"+name+"）",Str(rule,"payload")+(type=="DomainSuffix"?"（含子域名）":""),route,"—","—","—",state});
                }
            }catch{s.Errors.Add(name+"：未能读取本机控制 API；没有修改网络。");}
        }
        return s;
    }
    [STAThread] static int Main(string[] args) {
        try {
            if(File.Exists(Path.Combine(Root,"SKILL.md")))throw new Exception("Runtime data must remain outside the source skill.");
            if(args.Contains("--self-test")) {
                var process=Process.GetCurrentProcess();var identity=new Dictionary<string,object>{{"pid",process.Id},{"startTimeUtc",process.StartTime.ToUniversalTime().ToString("o")},{"executable",process.MainModule.FileName}};
                if(!MatchProcess(identity))throw new Exception("Limited process identity query failed");identity["startTimeUtc"]=DateTime.UtcNow.AddDays(-1).ToString("o");if(MatchProcess(identity))throw new Exception("Wrong process creation time accepted");
                var result=new {Domain=DomainRoute.SelfTest(),Search=ConnectionSearch.SelfTest(),Billing=Billing.SelfTest(),ProcessIdentity=new {Passed=2}};
                Directory.CreateDirectory(Path.Combine(Root,"data"));File.WriteAllText(Path.Combine(Root,"data","self-test.json"),new JavaScriptSerializer().Serialize(result),Encoding.UTF8);return 0;
            }
            if(args.Contains("--snapshot")) {
                var s=Load();Directory.CreateDirectory(Path.Combine(Root,"data"));File.WriteAllText(Path.Combine(Root,"data","snapshot.json"),new JavaScriptSerializer().Serialize(new {Cores=s.Cores,Tun=s.Tun,Current=s.Rows.Count,Rules=s.RuleRows,Protection=ProtectionStatus(),Errors=s.Errors}),Encoding.UTF8);return s.Cores>0?0:1;
            }
            Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
            using(var viewer=new Workbench()) {
                if(args.Contains("--preview")){viewer.Preview();return 0;}
                Application.Run(viewer);
            }
            return 0;
        }catch(Exception){return 1;}
    }
}
class Snapshot {
    internal DateTime At;
    internal int Cores,Direct,Proxy;
    internal bool Tun;
    internal long Download,Upload;
    internal List<string[]> Rows=new List<string[]>(),RuleRows=new List<string[]>();
    internal List<string> Errors=new List<string>();
}
class Workbench:Form {
    readonly TextBox query;readonly CheckBox proxyOnly;readonly ListView list;
    readonly Label overview,protection,message,hint,footer,speed;
    readonly Button setDirect,restoreDefault;
    readonly System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer(){Interval=2000};
    readonly ConnectionSearch history=new ConnectionSearch();
    bool loading,changing;Snapshot current,previous;
    static readonly Color Blue=Color.FromArgb(28,95,216),Green=Color.FromArgb(0,126,82);
    Label LabelAt(string text,int x,int y,int w,int h){var l=new Label(){Text=text,Location=new Point(x,y),Size=new Size(w,h)};Controls.Add(l);return l;}
    Button ButtonAt(string text,int x,int y,int w,Action action){var b=new Button(){Text=text,Location=new Point(x,y),Size=new Size(w,30),FlatStyle=FlatStyle.Flat,BackColor=Color.White};b.FlatAppearance.BorderColor=Color.FromArgb(190,210,240);b.Click+=(s,e)=>action();Controls.Add(b);return b;}
    internal Workbench() {
        Text="CCNetKit · CC护航";Font=new Font("Microsoft YaHei UI",9);BackColor=Color.White;ClientSize=new Size(980,660);MinimumSize=new Size(980,660);StartPosition=FormStartPosition.CenterScreen;
        LabelAt("CCNetKit · CC护航",22,20,700,30).Font=new Font(Font.FontFamily,14);
        overview=LabelAt("读取本机日常分流…",22,65,930,25);protection=LabelAt("专用保护状态：读取中…",22,98,930,32);
        speed=LabelAt("本次核心累计：—",22,140,930,24);
        ButtonAt("刷新状态",22,174,110,()=>RefreshSnapshot());
        ButtonAt("检查日常配置",144,174,135,()=>Diagnose());
        ButtonAt("离线使用说明",291,174,135,()=>{string file=Path.Combine(Program.Root,"HELP.md");if(File.Exists(file))Process.Start(new ProcessStartInfo("notepad.exe","\""+file+"\""){UseShellExecute=true});});
        ButtonAt("月度流量（可选）",438,174,155,()=>Billing.Show(this));
        message=LabelAt("查看只读；域名设置只修改日常配置，不启动或重置专用保护。",22,215,930,42);message.ForeColor=Blue;
        query=new TextBox(){Location=new Point(22,267),Size=new Size(360,25)};Controls.Add(query);LabelAt("搜索软件 / 域名 / 网址",395,270,260,25);
        proxyOnly=new CheckBox(){Text="只看代理线路",Location=new Point(760,267),Size=new Size(195,25)};Controls.Add(proxyOnly);
        setDirect=ButtonAt("设为国内直连",22,305,150,()=>ChangeRoute("Direct"));restoreDefault=ButtonAt("恢复默认分流",184,305,150,()=>ChangeRoute("Default"));
        hint=LabelAt("域名设置覆盖输入域名及其子域名",346,311,610,24);
        list=new ListView(){Location=new Point(22,348),Size=new Size(936,222),View=View.Details,FullRowSelect=true,HideSelection=false};list.Anchor=AnchorStyles.Top|AnchorStyles.Bottom|AnchorStyles.Left|AnchorStyles.Right;
        string[] headers={"软件 / 记录","目标域名 / IP","路线","协议","已下载","已上传","状态 / 最近时间"};int[] widths={145,245,90,55,80,80,220};for(int i=0;i<headers.Length;i++)list.Columns.Add(headers[i],widths[i]);Controls.Add(list);
        footer=LabelAt("",22,583,930,28);footer.Anchor=AnchorStyles.Left|AnchorStyles.Right|AnchorStyles.Bottom;
        LabelAt("近期记录仅保存在本窗口内存。规则命中不等于网页加载成功；专用连接沿用原有保护。",22,619,930,28).ForeColor=Color.DimGray;
        query.TextChanged+=(s,e)=>{Render();try{hint.Text=DomainRoute.Normalize(query.Text)+"（含子域名）";hint.ForeColor=Green;}catch{hint.Text="输入有效网址或域名后可设置分流";hint.ForeColor=Color.DimGray;}};
        proxyOnly.CheckedChanged+=(s,e)=>Render();timer.Tick+=(s,e)=>RefreshSnapshot();Shown+=(s,e)=>{RefreshSnapshot();timer.Start();};FormClosed+=(s,e)=>timer.Dispose();FormClosing+=(s,e)=>{if(changing)e.Cancel=true;};
    }
    async void RefreshSnapshot(){if(loading)return;loading=true;try{var s=await Task.Run(()=>Program.Load());if(IsDisposed)return;current=s;history.Observe(s.Rows,s.At);overview.Text="日常核心在线 "+s.Cores+" · TUN "+(s.Tun?"已启用":"未启用或未接入")+" · 当前连接 "+s.Rows.Count+"（代理 "+s.Proxy+" / 直连 "+s.Direct+"）";protection.Text=Program.ProtectionStatus();protection.ForeColor=protection.Text.Contains("守卫运行中")?Green:Color.FromArgb(150,80,0);speed.Text="本次核心累计：下载 "+Program.Size(s.Download)+" / 上传 "+Program.Size(s.Upload);previous=s;Render();}catch{if(!IsDisposed)footer.Text="状态读取失败，现有网络未改变。";}finally{loading=false;}}
    void Render(){if(current==null)return;var rows=history.Select(current,query.Text,proxyOnly.Checked);list.BeginUpdate();list.Items.Clear();foreach(var row in rows){var item=new ListViewItem(row.Take(7).ToArray());if(row[2]=="代理线路")item.ForeColor=Blue;else if(row[0].StartsWith("规则")&&row[2]=="直连")item.ForeColor=Green;else if(row[6].StartsWith("近期"))item.ForeColor=Color.DimGray;list.Items.Add(item);}list.EndUpdate();footer.Text=current.Errors.Count>0?String.Join("；",current.Errors):"更新于 "+current.At.ToString("HH:mm:ss")+" · 找到 "+rows.Count+" 条；搜索包含本窗口近 10 分钟记录及明确域名规则。";}
    async void Diagnose(){if(changing)return;changing=true;message.Text="正在执行本地配置与 API 检查…";try{await RunScript("Diagnose.ps1","");}finally{changing=false;}}
    async Task RunScript(string script,string arguments) {
        string request=Guid.NewGuid().ToString("N");string file=Path.Combine(Program.Root,"bin",script);
        var start=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),@"System32\WindowsPowerShell\v1.0\powershell.exe"),"-NoLogo -NoProfile -ExecutionPolicy Bypass -File \""+file+"\" -RequestId "+request+" "+arguments){UseShellExecute=true,WindowStyle=ProcessWindowStyle.Hidden};
        if(script=="Set-DomainRoute.ps1")start.Verb="runas";
        try{using(var p=Process.Start(start))await Task.Run(()=>p.WaitForExit());if(IsDisposed)return;var result=Program.ReadFile(Path.Combine(Program.Root,"data",script=="Diagnose.ps1"?"diagnostic-result.json":"route-result.json"));if(Program.Str(result,"RequestId")!=request)throw new Exception("操作结果不匹配。");message.Text=Program.Str(result,"Message");message.ForeColor=Program.Flag(result,"Success")?Green:Color.Firebrick;}
        catch(System.ComponentModel.Win32Exception ex){message.Text=ex.NativeErrorCode==1223?"已取消管理员许可，规则没有改变。":"无法启动本次操作。";}
        catch{message.Text="操作未确认完成，请查看本机 data 目录中的结果。";}
    }
    async void ChangeRoute(string action){if(changing)return;string domain;try{domain=DomainRoute.Normalize(query.Text);}catch(Exception e){message.Text=e.Message;return;}changing=true;query.Enabled=false;setDirect.Enabled=restoreDefault.Enabled=false;message.Text="正在处理 "+domain+"；如有管理员提示，请允许。";try{await RunScript("Set-DomainRoute.ps1","-Action "+action+" -Domain "+domain);}finally{changing=false;if(!IsDisposed){query.Enabled=true;setDirect.Enabled=restoreDefault.Enabled=true;if(action=="Direct")proxyOnly.Checked=false;RefreshSnapshot();}}}
    internal void Preview(){
        // No Load(), Settings, APIs, process enumeration, or desktop capture in this renderer.
        current=new Snapshot(){At=new DateTime(2026,1,1,10,30,0),Cores=1,Tun=true,Proxy=2,Direct=2};
        current.Rows.Add(new[]{"Browser.exe","api.example.com:443","代理线路","TCP","2.4 MB","128 KB","连接中","demo-1"});
        current.Rows.Add(new[]{"Chat.exe","media.example.com:443","直连","TCP","860 KB","3.2 MB","连接中","demo-2"});
        current.Rows.Add(new[]{"DevTool.exe","build.example.com:443","代理线路","TCP","6.8 MB","42 KB","连接中","demo-3"});
        current.Rows.Add(new[]{"Sync.exe","files.example.com:443","直连","TCP","1.1 MB","56 KB","连接中","demo-4"});
        current.RuleRows.Add(new[]{"规则命中（演示）","media.example.com（含子域名）","直连","—","—","—","命中 12 次 · 10:30:00"});
        Controls[0].Text="CCNetKit · CC护航 · 虚构数据演示";
        overview.Text="日常核心在线 1 · TUN 已启用 · 当前连接 4（代理 2 / 直连 2）";overview.ForeColor=Green;
        protection.Text="专用保护：演示环境未接入守卫；此图不代表已建立防直连隔离";protection.ForeColor=Color.FromArgb(150,80,0);
        speed.Text="本次核心累计：下载 1.2 GB / 上传 86.0 MB（虚构数据）";
        message.Text="全部为虚构演示数据。蓝色：代理线路；黑色：直连；绿色：域名直连规则。";
        query.Text="example.com";Render();CreateControl();
        using(var b=new Bitmap(ClientSize.Width,ClientSize.Height)){
            using(var g=Graphics.FromImage(b))g.Clear(Color.White);
            foreach(Control c in Controls){c.CreateControl();c.DrawToBitmap(b,new Rectangle(c.Left,c.Top,c.Width,c.Height));}
            Directory.CreateDirectory(Path.Combine(Program.Root,"data"));b.Save(Path.Combine(Program.Root,"data","preview.png"));
        }
    }
}
