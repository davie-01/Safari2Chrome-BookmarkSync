import json,sys
t=json.load(open(sys.argv[1])); name=sys.argv[2]
tree=t.get('tree',t)
def walk(n,path,parent,prev):
    for i,c in enumerate(n.get('children') or []):
        if c.get('title')==name:
            cnt=[0,0]
            def count(x):
                for y in x.get('children') or []:
                    cnt[0 if y['kind']=='folder' else 1]+=1; count(y)
            count(c)
            print(json.dumps({'path':path,'parent':n['id'],'index':i,'prev':(n['children'][i-1]['id'],n['children'][i-1]['title']) if i else None,'id':c['id'],'folders':cnt[0],'bookmarks':cnt[1]},ensure_ascii=False))
        walk(c,path+'/'+c.get('title',''),n,None)
for k,r in tree['roots'].items(): walk(r,k,None,None)
