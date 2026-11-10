/// EPUB parsing: `EpubParser().parseFile(path)` → [Book].
library;

export 'epub_parser.dart' show EpubParser;
export 'model.dart';
export 'sentence_splitter.dart' show SentenceSplitter;
export 'xhtml_converter.dart' show XhtmlConverter, ConvertedDocument;
