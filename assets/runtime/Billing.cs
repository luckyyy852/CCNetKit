using System;
using System.IO;
using System.Text;
using System.Net;
using System.Drawing;
using System.Security.Cryptography;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Threading.Tasks;

class Usage {
    internal double Used,Quota;
    internal DateTime Reset;
    internal static Usage Parse(object value,string expectedAddress){
        if(Program.Num(value,"error")!=0)throw new Exception("服务商没有接受查询。");
        var ips=Program.Val(value,"ip_addresses") as object[];
        if(ips==null||Array.IndexOf(ips,expectedAddress)<0)throw new Exception("返回的服务器与私人设置不符。");
        double quota,used,multiplier=1;
        if(!Double.TryParse(Program.Str(value,"plan_monthly_data"),System.Globalization.NumberStyles.Float,System.Globalization.CultureInfo.InvariantCulture,out quota)||!Double.TryParse(Program.Str(value,"data_counter"),System.Globalization.NumberStyles.Float,System.Globalization.CultureInfo.InvariantCulture,out used))throw new Exception("用量数据不完整。");
        if(Program.Val(value,"monthly_data_multiplier")!=null&&!Double.TryParse(Program.Str(value,"monthly_data_multiplier"),System.Globalization.NumberStyles.Float,System.Globalization.CultureInfo.InvariantCulture,out multiplier))throw new Exception("倍率无效。");
        if(quota<=0||used<0||multiplier<=0||Double.IsNaN(quota)||Double.IsNaN(used)||Double.IsNaN(multiplier)||Double.IsInfinity(quota*multiplier)||Double.IsInfinity(used*multiplier))throw new Exception("用量数值无效。");
        long reset=Program.Num(value,"data_next_reset");if(reset<=0)throw new Exception("重置时间无效。");
        return new Usage(){Used=used*multiplier,Quota=quota*multiplier,Reset=new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc).AddSeconds(reset)};
    }
    internal string Display(){return "本期已用 "+Program.Size(Used)+" / "+Program.Size(Quota)+"；剩余 "+Program.Size(Math.Max(0,Quota-Used))+"\n重置："+Reset.ToLocalTime().ToString("yyyy-MM-dd HH:mm")+(DateTime.UtcNow>=Reset?"（上周期缓存）":"");}
}
static class Billing {
    static readonly byte[] Entropy=Encoding.UTF8.GetBytes("NetworkWorkbench-KiwiVM-v1");
    static string KeyPath {get{return Path.Combine(Program.Root,"data","billing.dpapi");}}
    internal static object Options {get{try{return Program.Val(Program.Settings,"Billing");}catch{return null;}}}
    internal static bool Enabled {get{IPAddress address;return Program.Str(Options,"Provider")=="kiwivm"&&System.Text.RegularExpressions.Regex.IsMatch(Program.Str(Options,"VpsId"),@"^\d+$")&&IPAddress.TryParse(Program.Str(Options,"ExpectedIPv4"),out address);}}
    internal static string LoadKey(){try{byte[] plain=ProtectedData.Unprotect(File.ReadAllBytes(KeyPath),Entropy,DataProtectionScope.CurrentUser);try{return Encoding.UTF8.GetString(plain);}finally{Array.Clear(plain,0,plain.Length);}}catch{return "";}}
    internal static Usage Query(string key){
        if(!Enabled||String.IsNullOrWhiteSpace(key))throw new Exception("月度查询未在本机设置中配置。");
        ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
        var r=(HttpWebRequest)WebRequest.Create("https://api.64clouds.com/v1/getServiceInfo");r.Method="POST";r.AllowAutoRedirect=false;r.Timeout=10000;r.ReadWriteTimeout=10000;r.ContentType="application/x-www-form-urlencoded";r.Proxy=WebRequest.GetSystemWebProxy();
        byte[] body=Encoding.UTF8.GetBytes("veid="+Uri.EscapeDataString(Program.Str(Options,"VpsId"))+"&api_key="+Uri.EscapeDataString(key));
        try{r.ContentLength=body.Length;using(var stream=r.GetRequestStream())stream.Write(body,0,body.Length);using(var response=r.GetResponse())using(var reader=new StreamReader(response.GetResponseStream()))return Usage.Parse(new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd()),Program.Str(Options,"ExpectedIPv4"));}
        finally{Array.Clear(body,0,body.Length);}
    }
    internal static void Save(string key){byte[] plain=Encoding.UTF8.GetBytes(key);try{File.WriteAllBytes(KeyPath,ProtectedData.Protect(plain,Entropy,DataProtectionScope.CurrentUser));}finally{Array.Clear(plain,0,plain.Length);}}
    internal static object SelfTest(){
        var json=new JavaScriptSerializer();string synthetic="{\"error\":0,\"ip_addresses\":[\"192.0.2.10\"],\"plan_monthly_data\":1000,\"data_counter\":100,\"monthly_data_multiplier\":1,\"data_next_reset\":2000000000}";
        var normal=Usage.Parse(json.DeserializeObject(synthetic),"192.0.2.10");if(normal.Used!=100||normal.Quota!=1000)throw new Exception("Usage parsing");
        bool wrong=false;try{Usage.Parse(json.DeserializeObject(synthetic),"192.0.2.11");}catch{wrong=true;}if(!wrong)throw new Exception("Wrong server accepted");
        bool missing=false;try{Usage.Parse(json.DeserializeObject("{}"),"192.0.2.10");}catch{missing=true;}if(!missing)throw new Exception("Incomplete usage accepted");
        byte[] clear=Encoding.UTF8.GetBytes("synthetic-only");byte[] encrypted=ProtectedData.Protect(clear,Entropy,DataProtectionScope.CurrentUser);if(Encoding.UTF8.GetString(ProtectedData.Unprotect(encrypted,Entropy,DataProtectionScope.CurrentUser))!="synthetic-only")throw new Exception("DPAPI roundtrip");Array.Clear(clear,0,clear.Length);
        return new {Passed=4,RealCredentialsUsed=false,ExternalApiCalled=false};
    }
    internal static void Show(IWin32Window owner){if(!Enabled){MessageBox.Show(owner,"月度查询是可选功能。请在仓库外的私人设置中配置 Billing 的 Provider、VpsId、ExpectedIPv4；密钥不用写进设置文件。","月度流量");return;}using(var form=new BillingWindow())form.ShowDialog(owner);}
}
class BillingWindow:Form {
    readonly TextBox key;readonly Label result;readonly Button query;
    internal BillingWindow(){Text="月度流量（KiwiVM）";ClientSize=new Size(650,260);Font=new Font("Microsoft YaHei UI",9);BackColor=Color.White;StartPosition=FormStartPosition.CenterParent;
        Controls.Add(new Label(){Text="只在本机输入 API Key。验证成功后按当前 Windows 用户加密保存；\n该密钥可能具有服务器管理权限，本工具只执行用量查询。",Location=new Point(20,20),Size=new Size(610,48)});
        key=new TextBox(){Location=new Point(20,85),Size=new Size(460,25),UseSystemPasswordChar=true,Text=Billing.LoadKey()};Controls.Add(key);
        query=new Button(){Text="查询并保存",Location=new Point(495,82),Size=new Size(135,30)};Controls.Add(query);query.Click+=async(s,e)=>await Fetch();
        result=new Label(){Text="不会自动查询或把密钥发送给聊天助手。",Location=new Point(20,135),Size=new Size(610,95)};Controls.Add(result);
        FormClosing+=(s,e)=>{if(!query.Enabled)e.Cancel=true;};
    }
    async Task Fetch(){query.Enabled=false;key.Enabled=false;result.Text="查询中…";string value=key.Text;try{var usage=await Task.Run(()=>Billing.Query(value));Billing.Save(value);result.Text=usage.Display()+"\n密钥已在本机加密保存。";}catch{result.Text="查询未成功。原有保存信息保持不变；没有操作服务器或更改网络。";}finally{query.Enabled=true;key.Enabled=true;}}
}
