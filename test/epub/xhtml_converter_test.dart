import 'package:epub_reader/epub/epub.dart';
import 'package:flutter_test/flutter_test.dart';

ConvertedDocument convert(String body, {String path = 'OEBPS/ch1.xhtml'}) {
  return const XhtmlConverter().convert(
    '<?xml version="1.0" encoding="utf-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head>'
    '<body>$body</body></html>',
    documentPath: path,
  );
}

void main() {
  group('XhtmlConverter', () {
    test('paragraphs, headings and collapsed whitespace', () {
      final doc = convert('''
        <h2 id="c1">CHAPTER I.<br/>
        Down the Rabbit-Hole</h2>
        <p>
          Alice was   beginning to get
          very tired.
        </p>''');
      expect(doc.blocks.map((b) => b.type), [
        BlockType.heading,
        BlockType.paragraph,
      ]);
      expect(doc.blocks[0].level, 2);
      expect(doc.blocks[0].text, 'CHAPTER I.\nDown the Rabbit-Hole');
      expect(doc.blocks[0].sentences, hasLength(1));
      expect(doc.blocks[1].text, 'Alice was beginning to get very tired.');
      expect(doc.anchors['c1'], 0);
    });

    test('inline styles become runs', () {
      final doc = convert(
        '<p>So <i>very</i> <b>bold</b> and <span class="smcap">small</span>, '
        '<a href="ch2.xhtml#x">link</a>.</p>',
      );
      final runs = doc.blocks.single.inlines;
      expect(doc.blocks.single.text, 'So very bold and small, link.');
      expect(runs.firstWhere((r) => r.text == 'very').italic, isTrue);
      expect(runs.firstWhere((r) => r.text == 'bold').bold, isTrue);
      expect(runs.firstWhere((r) => r.text == 'small').smallCaps, isTrue);
      expect(
        runs.firstWhere((r) => r.text == 'link').href,
        'OEBPS/ch2.xhtml#x',
      );
    });

    test('Gutenberg boilerplate and page numbers are skipped', () {
      final doc = convert('''
        <header class="pg-boilerplate pgheader" id="pg-header">
          <h2>The Project Gutenberg eBook</h2>
          <div>*** START OF THE PROJECT GUTENBERG EBOOK ***</div>
        </header>
        <p>Real text.<span class="x-ebookmaker-pageno" title="{3}"><a id="page_3"/></span></p>
        <footer class="pg-boilerplate">License</footer>''');
      expect(doc.blocks.map((b) => b.text), ['Real text.']);
    });

    test('poem keeps line breaks and indentation', () {
      final doc = convert('''
        <p class="poem">
        “How doth the little crocodile<br/>
            Improve his shining tail,<br/>
        <br/>
        And pour the waters of the Nile</p>''');
      final block = doc.blocks.single;
      expect(block.type, BlockType.verse);
      expect(
        block.text,
        '“How doth the little crocodile\n'
        '    Improve his shining tail,\n'
        '\n'
        'And pour the waters of the Nile',
      );
    });

    test('pre is dedented, keeps relative indentation', () {
      final doc = convert('''
<pre>
  Still though the one I sing,
  I leave in him revolt, (O
      quenchless fire!)
</pre>''');
      expect(doc.blocks.single.type, BlockType.verse);
      expect(
        doc.blocks.single.text,
        'Still though the one I sing,\n'
        'I leave in him revolt, (O\n'
        '    quenchless fire!)',
      );
    });

    test('illustrated drop cap becomes text', () {
      final doc = convert(
        '<p class="nind"><span class="letra">\n'
        '<img alt="W" src="i_098_b.png"/></span>HEN the ladies removed.</p>',
      );
      expect(doc.blocks.single.text, 'WHEN the ladies removed.');
    });

    test('image in a heading with caption: image, caption, heading', () {
      final doc = convert('''
        <h2><a id="CHAPTER_XI"/><img alt="" src="images/i_098_a.jpg"/>
        <br/><span class="caption">Piling up the fire.</span><br/><br/>
        CHAPTER XI.</h2>''', path: 'OEBPS/text/ch.xhtml');
      expect(doc.blocks.map((b) => b.type), [
        BlockType.image,
        BlockType.caption,
        BlockType.heading,
      ]);
      expect(doc.blocks[0].imagePath, 'OEBPS/text/images/i_098_a.jpg');
      expect(doc.blocks[1].text, 'Piling up the fire.');
      expect(doc.blocks[2].text, 'CHAPTER XI.');
      expect(doc.anchors['CHAPTER_XI'], 0);
    });

    test('figure caption paragraphs stay captions', () {
      final doc = convert('''
        <div class="figcenter"><img alt="" src="i_172.jpg"/>
          <div class="caption"><div class="blockquot"><p>“they entered”</p></div>
          <p>[<i>Copyright 1894</i>]</p></div>
        </div>''');
      expect(doc.blocks.map((b) => b.type), [
        BlockType.image,
        BlockType.caption,
        BlockType.caption,
      ]);
    });

    test('footnotes, blockquotes, separators and tables', () {
      final doc = convert(
        '''
        <blockquote><p>Dear Sir,</p></blockquote>
        <hr/>
        <p class="footnote">[1] A note.</p>
        <table><tr><td><a href="#c1">CHAPTER I.</a></td><td>Down the Rabbit-Hole</td></tr></table>''',
      );
      expect(doc.blocks.map((b) => b.type), [
        BlockType.quote,
        BlockType.separator,
        BlockType.footnote,
        BlockType.paragraph,
      ]);
      expect(doc.blocks.last.text, 'CHAPTER I. Down the Rabbit-Hole');
      expect(doc.blocks.last.inlines.first.href, 'OEBPS/ch1.xhtml#c1');
    });

    test('HTML entities are decoded', () {
      final doc = convert('<p>A&nbsp;B &mdash; C &amp; D</p>');
      expect(doc.blocks.single.text, 'A B — C & D');
    });
  });
}
