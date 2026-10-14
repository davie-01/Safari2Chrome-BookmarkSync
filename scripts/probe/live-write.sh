#!/bin/bash
# 实测：Safari 运行时写入 Bookmarks.plist 的行为。用法：live-write.sh add|remove|watch <秒>
B=~/Applications/BookmarkSync.app/Contents/MacOS/bmsync
F=~/Library/Safari/Bookmarks.plist
D="$(cd "$(dirname "$0")" && pwd)"; ST="$D/.probe-state"; mkdir -p "$ST"
has() { python3 -c "import plistlib,sys;d=open('$F','rb').read();print('yes' if b'$1' in d or '$1' in str(plistlib.loads(d)) else 'no')"; }
watch() { local n=$1; local last=""; for i in $(seq 1 $n); do
  cur="$(stat -f '%m %z' "$F")"; if [ "$cur" != "$last" ]; then
    echo "[$(date +%T)] mtime/size=$cur folder=$(has "$(cat $ST/folder)") leaf=$(has "$(cat $ST/leaf)") safari=$(pgrep -x Safari >/dev/null && echo running || echo quit)"; last="$cur"; fi; sleep 1; done; }
case "$1" in
  add)
    FOLDER=$(uuidgen); LEAF=$(uuidgen); echo $FOLDER > $ST/folder; echo $LEAF > $ST/leaf
    cat > $ST/ops.json <<J
[{"op":"create","id":"$FOLDER","kind":"folder","title":"BookmarkSync 实时写入测试","parent":"root:bar","after":"END"},
 {"op":"create","id":"$LEAF","kind":"bookmark","title":"实时写入测试书签","url":"https://example.invalid/bookmarksync-live-probe","parent":"$FOLDER","after":"END"}]
J
    echo "safari: $(pgrep -x Safari >/dev/null && echo running || echo quit)"
    $B apply --real --allow-running --file "$F" --ops $ST/ops.json
    watch ${2:-60};;
  remove)
    FOLDER=$(cat $ST/folder)
    echo "[{\"op\":\"remove\",\"id\":\"$FOLDER\"}]" > $ST/rm.json
    $B apply --real --allow-running --file "$F" --ops $ST/rm.json
    watch ${2:-30};;
  watch) watch ${2:-60};;
  find)
    python3 - "$(cat $ST/folder)" <<'P'
import plistlib,os,sys
s=plistlib.load(open(os.path.expanduser('~/Library/Safari/Bookmarks.plist'),'rb'))
hits=[]
def w(n,p):
    for c in n.get('Children',[]):
        t=c.get('Title') or (c.get('URIDictionary') or {}).get('title')
        if t and ('实时写入测试' in t): hits.append((p,t,c.get('WebBookmarkUUID'),len(c.get('Children',[]))))
        w(c,p+'/'+str(t))
w(s,'')
print("test nodes by title:",hits, "original uuid:",sys.argv[1])
P
    ;;
esac
