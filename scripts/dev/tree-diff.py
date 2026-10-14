import json,sys
def load(p):
    t=json.load(open(p)); t=t.get('tree',t); m={}
    def w(x,path):
        for i,c in enumerate(x.get('children') or []):
            m[c['id']]=(path,c['kind'],c.get('title'),c.get('url'),len(c.get('children') or []))
            w(c,path+'/'+(c.get('title') or ''))
    for k,r in t['roots'].items(): w(r,k)
    return m
a,b=load(sys.argv[1]),load(sys.argv[2])
for k in a:
    if k not in b: print('  - removed',a[k])
for k in b:
    if k not in a: print('  + added',b[k])
    elif a[k][:4]!=b[k][:4]: print('  ~ changed',a[k],'->',b[k])
