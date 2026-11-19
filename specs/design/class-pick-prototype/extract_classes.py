import re,json,glob,os,sys
out=[]
def aname(p):
    f=p.replace('res://','')
    try: t=open(f,encoding='utf8').read()
    except: return None
    m=re.search(r'ability_name\s*=\s*"([^"]+)"',t)
    tags=re.findall(r'&"(Ability\.Type\.[A-Za-z]+)"',t)
    nm=m.group(1) if m else os.path.basename(f)[:-5].replace('_',' ').title()
    return nm,sorted(set(tags))
for f in sorted(glob.glob('content/demo/characters/*.tres')):
    t=open(f,encoding='utf8').read()
    ext={m.group(2):m.group(1) for m in re.finditer(r'path="([^"]+)" id="([^"]+)"',t)}
    g=lambda k: (re.search(k+r' = "([^"]*)"',t) or [None,None])[1]
    ab=re.search(r'^abilities = .*?\(\[(.*)\]\)',t,re.M).group(1)
    abl=[aname(ext[i]) for i in re.findall(r'ExtResource\("([^"]+)"\)',ab)]
    lv=[(int(m.group(1)),aname(ext[m.group(2)])[0]) for m in re.finditer(r'level = (\d+)\nability = ExtResource\("([^"]+)"\)',t)]
    st={k:int(v) for k,v in re.findall(r'"(\w+)": (\d+)',t)}
    col=re.search(r'display_color = Color\(([^)]*)\)',t).group(1)
    out.append(dict(id=os.path.basename(f)[:-5],name=g('display_name'),role=g('role'),desc=g('description'),color=[float(x) for x in col.split(',')],core='Card.Set.Core' in t,abilities=abl,levels=lv,stats={k:st[k]/100 for k in ['max_hp','atk','def','spd','max_mp','crit_rate','crit_dmg'] if k in st}))
print(json.dumps(out,indent=0))
