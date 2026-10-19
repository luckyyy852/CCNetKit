using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Collections.Generic;
using System.Web.Script.Serialization;

static class MockCore {
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    static object Get(object item,string key){object value;var map=item as Dictionary<string,object>;return map!=null&&map.TryGetValue(key,out value)?value:null;}
    static string ConfigPath;
    static object Loaded;
    static object ReadConfig(){return Json.DeserializeObject(File.ReadAllText(ConfigPath,Encoding.UTF8));}
    static int Main(string[] args){
        if(Array.IndexOf(args,"-t")>=0){int i=Array.IndexOf(args,"-f");if(i<0||i+1>=args.Length)return 2;string text=File.ReadAllText(args[i+1],Encoding.UTF8);Json.DeserializeObject(text);return text.Contains("configfail.invalid")?2:0;}
        if(args.Length!=2)return 3;
        int port=Int32.Parse(args[0]);ConfigPath=Path.GetFullPath(args[1]);Loaded=ReadConfig();
        var listener=new TcpListener(IPAddress.Loopback,port);listener.Start();
        while(true)using(var client=listener.AcceptTcpClient())using(var stream=client.GetStream()){
            var head=new List<byte>();int next;while((next=stream.ReadByte())>=0){head.Add((byte)next);int n=head.Count;if(n>=4&&head[n-4]==13&&head[n-3]==10&&head[n-2]==13&&head[n-1]==10)break;if(n>65536)throw new Exception("Test request header too large");}
            string[] lines=Encoding.ASCII.GetString(head.ToArray()).Split(new[]{"\r\n"},StringSplitOptions.None);if(lines.Length==0)continue;var request=lines[0].Split(' ');int length=0;string auth="";
            foreach(string line in lines){int colon=line.IndexOf(':');if(colon<0)continue;string name=line.Substring(0,colon);string value=line.Substring(colon+1).Trim();if(name.Equals("Content-Length",StringComparison.OrdinalIgnoreCase))length=Int32.Parse(value);if(name.Equals("Authorization",StringComparison.OrdinalIgnoreCase))auth=value;}
            byte[] bodyBytes=new byte[length];int consumed=0;while(consumed<length){int n=stream.Read(bodyBytes,consumed,length-consumed);if(n<=0)break;consumed+=n;}string body=Encoding.UTF8.GetString(bodyBytes,0,consumed);int status=200;object answer=new Dictionary<string,object>();
            if(auth!="Bearer synthetic-local-token")status=401;
            else if(request[0]=="PUT"&&request[1].StartsWith("/configs")){
                var input=Json.DeserializeObject(body);if(Path.GetFullPath(Convert.ToString(Get(input,"path")))!=ConfigPath)status=400;
                else if(File.ReadAllText(ConfigPath).Contains("reloadfail.invalid"))status=500;
                else{Loaded=ReadConfig();status=204;}
            }else if(request[1]=="/configs")answer=new {mode=Convert.ToString(Get(Loaded,"mode")),tun=new {enable=false}};
            else if(request[1]=="/rules"){
                var rules=new List<object>();foreach(string rule in Get(Loaded,"rules") as object[]??new object[0]){var parts=rule.Split(',');string kind=parts[0]=="DOMAIN-SUFFIX"?"DomainSuffix":parts[0]=="DOMAIN"?"Domain":parts[0];rules.Add(new {type=kind,payload=parts.Length>1?parts[1]:"",proxy=parts[parts.Length-1],extra=new {hitCount=0}});}answer=new {rules=rules};
            }else if(request[1]=="/connections")answer=new {connections=new[]{new {id="synthetic-connection",metadata=new {process="example-browser.exe",host="example.com",destinationIP="192.0.2.20",destinationPort=443,network="tcp"},chains=new[]{"DIRECT"},download=1024,upload=512}},downloadTotal=1024,uploadTotal=512};
            else status=404;
            byte[] payload=Encoding.UTF8.GetBytes(status==204?"":Json.Serialize(answer));string header="HTTP/1.1 "+status+" Test\r\nContent-Type: application/json\r\nContent-Length: "+payload.Length+"\r\nConnection: close\r\n\r\n";byte[] bytes=Encoding.ASCII.GetBytes(header);stream.Write(bytes,0,bytes.Length);stream.Write(payload,0,payload.Length);stream.Flush();
        }
    }
}
