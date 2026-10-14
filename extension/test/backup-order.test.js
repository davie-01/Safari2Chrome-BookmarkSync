import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseBookmarkHtml, restoreChromeOrder } from '../backup-order.js';
import { FakeChrome } from './fakes.js';

const HTML = `<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
<DL><p>
    <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">书签栏</H3>
    <DL><p>
        <DT><H3 ADD_DATE="1">学习 &amp; 考试</H3>
        <DL><p>
            <DT><A HREF="https://b.test/" ADD_DATE="1">B</A>
            <DT><A HREF="https://a.test/" ADD_DATE="1">A</A>
            <DT><A HREF="https://dup.test/" ADD_DATE="1">Dup</A>
            <DT><A HREF="https://dup.test/" ADD_DATE="1">Dup</A>
        </DL><p>
        <DT><A HREF="https://x.test/" ADD_DATE="1">X</A>
        <DT><H3>工作</H3>
        <DL><p>
        </DL><p>
    </DL><p>
</DL><p>`;

test('parse Chrome export', () => {
  const b = parseBookmarkHtml(HTML);
  assert.equal(b.bar.title, '书签栏');
  assert.deepEqual(b.bar.children.map((c) => c.title), ['学习 & 考试', 'X', '工作']);
  assert.deepEqual(b.bar.children[0].children.map((c) => c.title), ['B', 'A', 'Dup', 'Dup']);
});

test('restore reorders only, recursively, keeps unmatched at the end', async () => {
  const c = new FakeChrome();
  const extra = c.add('1', 'Only in Chrome', 'https://only.test/');
  const work = c.add('1', '工作');
  c.add('1', 'X', 'https://x.test/');
  const f = c.add('1', '学习 & 考试');
  const d1 = c.add(f, 'Dup', 'https://dup.test/');
  c.add(f, 'A', 'https://a.test/');
  const d2 = c.add(f, 'Dup', 'https://dup.test/');
  c.add(f, 'B', 'https://b.test/');
  const before = c.nodes.size;
  const stats = await restoreChromeOrder(c, { 'root:bar': '1', 'root:other': '2' }, parseBookmarkHtml(HTML));
  assert.equal(c.nodes.size, before, 'nothing created or removed');
  const titles = (id) => c.nodes.get(id).children.map((k) => c.nodes.get(k).title);
  assert.deepEqual(titles('1'), ['学习 & 考试', 'X', '工作', 'Only in Chrome']);
  assert.deepEqual(titles(f), ['B', 'A', 'Dup', 'Dup']);
  assert.deepEqual(c.nodes.get(f).children.slice(2), [d1, d2], 'duplicates keep their relative order');
  assert.equal(stats.unmatched, 1);
  void extra; void work;
});
