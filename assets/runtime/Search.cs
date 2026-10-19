using System;using System.Linq;using System.Collections.Generic;using System.Net;
class DomainRoute {
    internal static string Normalize(string input) {
        string value=(input??"").Trim();Uri uri;
        if(value.Length==0||System.Text.RegularExpressions.Regex.IsMatch(value,"[\\s*\\\"'<>]"))throw new ArgumentException("请输入有效网址或域名，不要输入软件名或通配符。");
        if(!System.Text.RegularExpressions.Regex.IsMatch(value,"^[a-zA-Z][a-zA-Z0-9+.-]*://"))value="https://"+value;
        if(!Uri.TryCreate(value,UriKind.Absolute,out uri)||(uri.Scheme!="https"&&uri.Scheme!="http")||uri.UserInfo.Length>0)throw new ArgumentException("只支持 http/https 网址或域名。");
        string domain=new System.Globalization.IdnMapping().GetAscii(uri.DnsSafeHost.TrimEnd('.')).ToLowerInvariant();
        if(domain.StartsWith("www."))domain=domain.Substring(4);
        IPAddress address;
        if(IPAddress.TryParse(domain,out address)||domain.Length>253||domain.EndsWith(".exe")||!System.Text.RegularExpressions.Regex.IsMatch(domain,@"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$"))throw new ArgumentException("请填写完整网站域名，例如 example.com。");
        return domain;
    }
    internal static object SelfTest() {
        var cases=new Dictionary<string,string>{{"https://www.Example.com/path?q=1","example.com"},{"example.com/path","example.com"},{"sub.example.com:443","sub.example.com"},{"https://例子.中国/","xn--fsqu00a.xn--fiqs8s"}};
        foreach(var item in cases)if(Normalize(item.Key)!=item.Value)throw new Exception("Domain normalization: "+item.Key);
        foreach(string value in new[]{"","*.example.com","com","127.0.0.1","https://u:p@example.com/","file:///c:/test","chatgpt.exe","example.com,REJECT","https://example.com;evil/"}){
            bool rejected=false;try{Normalize(value);}catch{rejected=true;}if(!rejected)throw new Exception("Invalid input accepted: "+value);
        }
        return new {Passed=13};
    }
}
class SeenConnection {
    internal string[] Row;
    internal DateTime LastSeen;
}
class ConnectionSearch {
    readonly Dictionary<string,SeenConnection> history=new Dictionary<string,SeenConnection>();
    internal static string Normalize(string query) {
        query=(query??"").Trim();Uri uri;
        if((query.StartsWith("https://",StringComparison.OrdinalIgnoreCase)||query.StartsWith("http://",StringComparison.OrdinalIgnoreCase))&&Uri.TryCreate(query,UriKind.Absolute,out uri))return uri.Host;
        return query;
    }
    internal void Observe(List<string[]> rows,DateTime at) {
        foreach(var row in rows)history[row[7]]=new SeenConnection(){Row=(string[])row.Clone(),LastSeen=at};
        foreach(var key in history.Where(x=>(at-x.Value.LastSeen).TotalMinutes>10).Select(x=>x.Key).ToArray())history.Remove(key);
        foreach(var key in history.OrderByDescending(x=>x.Value.LastSeen).Skip(1000).Select(x=>x.Key).ToArray())history.Remove(key);
    }
    internal List<string[]> Select(Snapshot snapshot,string query,bool onlyVps) {
        query=Normalize(query);
        var candidates=new List<string[]>(snapshot.Rows);
        if(query.Length>0) {
            var active=new HashSet<string>(snapshot.Rows.Select(r=>r[7]));
            foreach(var seen in history.Values.Where(x=>!active.Contains(x.Row[7])&&(snapshot.At-x.LastSeen).TotalMinutes<=10).OrderByDescending(x=>x.LastSeen)) {
                var row=(string[])seen.Row.Clone();row[6]="近期 "+seen.LastSeen.ToString("HH:mm:ss");candidates.Add(row);
            }
            candidates.AddRange(snapshot.RuleRows);
        }
        return candidates.Where(r=>(!onlyVps||r[2]=="代理线路")&&(query.Length==0||(r[0]+" "+r[1]).IndexOf(query,StringComparison.OrdinalIgnoreCase)>=0)).Take(300).ToList();
    }
    internal static object SelfTest() {
        var search=new ConnectionSearch();DateTime at=DateTime.Now;
        var first=new Snapshot(){At=at};
        first.Rows.Add(new[]{"msedge.exe","example.com:443","直连","TCP","1 KB","2 KB","连接中","test-1"});
        search.Observe(first.Rows,first.At);
        if(search.Select(first,"https://example.com/account/",false).Count!=1)throw new Exception("URL normalization");
        if(search.Select(first,"MSEDGE",false).Count!=1)throw new Exception("Process search");
        if(search.Select(first,"example.com",true).Count!=0)throw new Exception("VPS filter");
        var later=new Snapshot(){At=at.AddSeconds(2)};
        later.RuleRows.Add(new[]{"规则命中（TUN）","example.com（及其子域名）","直连","—","—","—","命中 7 次 · 12:00:00"});
        search.Observe(later.Rows,later.At);
        var result=search.Select(later,"example.com",false);
        if(result.Count!=2||!result[0][6].StartsWith("近期")||!result[1][0].StartsWith("规则"))throw new Exception("Recent versus rule evidence");
        if(search.Select(later,"",false).Count!=0)throw new Exception("Default shows only current connections");
        if(search.Select(later,"unrelated.example",false).Count!=0)throw new Exception("Unmatched query");
        later.At=at.AddMinutes(11);search.Observe(later.Rows,later.At);
        if(search.Select(later,"example.com",false).Count!=1)throw new Exception("History expiration");
        return new {Passed=7,HistoryMinutes=10,HistoryLimit=1000,NetworkChanged=false};
    }
}
