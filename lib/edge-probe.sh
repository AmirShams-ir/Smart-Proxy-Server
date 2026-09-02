#!/usr/bin/env bash
# Smart Proxy Server - Real Proxy Probe
set -Eeuo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config/defaults.conf"

VERIFIED_FILE="${EDGE_VERIFIED_FILE:-$BASE_DIR/cache/verified.json}"
OUT="${EDGE_PROBE_FILE:-$BASE_DIR/cache/probed.json}"
PROBE_TIMEOUT="${EDGE_PROBE_TIMEOUT:-15}"
PROBE_LIMIT="${EDGE_PROBE_LIMIT:-20}"
PROXY_PORT="${EDGE_PROBE_PORT:-$((SOCKS_PORT+100))}"
mkdir -p "$(dirname "$OUT")"

[[ -f "$VERIFIED_FILE" ]] || { echo "verified file not found: $VERIFIED_FILE" >&2; exit 2; }
python3 - "$VERIFIED_FILE" "$OUT" "$PROBE_TIMEOUT" "$PROBE_LIMIT" "$PROXY_PORT" "$CONFIG_FILE" "$BASE_DIR" <<'PY'
import json, os, re, subprocess, sys, tempfile, time
from urllib.parse import parse_qs, urlparse, unquote

src,dst,timeout,limit,proxy_port,config_file,base_dir=sys.argv[1:]
timeout=float(timeout); limit=int(limit); proxy_port=int(proxy_port)
data=json.load(open(src,encoding='utf-8'))
uri_path=None
profile=data.get('profile','')
profile_file=os.path.join(base_dir,'profiles',profile)
if not os.path.isfile(profile_file):
    p2=os.path.join('/etc/sing-box/profiles',profile)
    if os.path.isfile(p2): profile_file=p2
if not os.path.isfile(profile_file): raise SystemExit('profile file not found')
uri=open(profile_file,encoding='utf-8').readline().strip()
p=urlparse(uri); q=parse_qs(p.query)
orig_host=p.hostname; orig_port=p.port or 443

def first(k,d=''): return q.get(k,[d])[0]
transport=first('type').lower(); security=first('security').lower(); sni=first('sni') or orig_host; host=first('host') or orig_host

def make_config(edge_ip,listen):
    ob={'type':p.scheme,'tag':'probe','server':edge_ip,'server_port':orig_port}
    if p.scheme=='vless': ob['uuid']=unquote(p.username or ''); ob['packet_encoding']='xudp'
    elif p.scheme=='trojan': ob['password']=unquote(p.username or '')
    else: raise ValueError('unsupported scheme')
    tls_needed=(orig_port in {443,2053,2083,2087,2096,8443}) if security not in ('none','tls') else security=='tls'
    if orig_port in {80,8080,8880,2052,2082,2086,2095}: tls_needed=False
    if tls_needed:
        tls={'enabled':True,'server_name':sni,'insecure':first('insecure','0').lower() in ('1','true','yes')}
        if first('alpn'): tls['alpn']=[x.strip() for x in first('alpn').split(',') if x.strip()]
        elif transport=='ws': tls['alpn']=['http/1.1']
        if first('fp'): tls['utls']={'enabled':True,'fingerprint':first('fp')}
        ob['tls']=tls
    if transport=='ws':
        raw=unquote(first('path','/')); ed=None
        m=re.search(r'\?ed=([0-9]+)$',raw)
        if m: ed=int(m.group(1)); raw=raw[:m.start()]
        tr={'type':'ws','path':raw}
        if first('host'): tr['headers']={'Host':host}
        if ed is not None: tr['max_early_data']=ed; tr['early_data_header_name']='Sec-WebSocket-Protocol'
        ob['transport']=tr
    elif transport=='grpc':
        tr={'type':'grpc'}
        if first('serviceName'): tr['service_name']=first('serviceName')
        ob['transport']=tr
    return {'log':{'level':'error','timestamp':True},'inbounds':[{'type':'socks','tag':'probe-in','listen':'127.0.0.1','listen_port':listen}],'outbounds':[ob,{'type':'direct','tag':'direct' }],'route':{'auto_detect_interface':True,'rules':[{'inbound':['probe-in'],'action':'sniff'}],'final':'probe'}}

results=[]
for item in data.get('candidates',[])[:limit]:
    ip=item['ip']
    with tempfile.TemporaryDirectory(prefix='smartproxy-probe-') as td:
        cfg=os.path.join(td,'config.json')
        json.dump(make_config(ip,proxy_port),open(cfg,'w'),indent=2)
        p=subprocess.run(['sing-box','check','-c',cfg],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=5)
        if p.returncode!=0: continue
        proc=subprocess.Popen(['sing-box','run','-c',cfg],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            deadline=time.time()+5
            ready=False
            while time.time()<deadline:
                try:
                    import socket
                    s=socket.create_connection(('127.0.0.1',proxy_port),timeout=.2); s.close(); ready=True; break
                except Exception: time.sleep(.1)
            if not ready: continue
            t=time.perf_counter()
            r=subprocess.run(['curl','-4','--max-time',str(int(timeout)),'--connect-timeout','5','--socks5-hostname',f'127.0.0.1:{proxy_port}','-sS','-o','/dev/null','-w','%{http_code}', 'https://cp.cloudflare.com/generate_204'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=timeout+3)
            ms=(time.perf_counter()-t)*1000
            code=r.stdout.strip()
            results.append({**item,'proxy_http_code':code,'proxy_ms':round(ms,3),'proxy_ok':code=='204'})
        except Exception:
            pass
        finally:
            proc.terminate()
            try: proc.wait(timeout=1)
            except Exception: proc.kill()
results=[x for x in results if x.get('proxy_ok')]
results.sort(key=lambda x:x.get('proxy_ms',999999))
outdata={**{k:data.get(k) for k in ('profile','port','transport','security','sni','host')},'probed_at':int(time.time()),'candidates':results}
with open(dst,'w',encoding='utf-8') as f: json.dump(outdata,f,indent=2); f.write('\n')
print(json.dumps({'checked':min(limit,len(data.get('candidates',[]))),'proxy_ok':len(results),'output':dst},indent=2))
PY
