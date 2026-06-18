class DouyinParser {
  static final _urlRegex = RegExp(r'https://v\.douyin\.com/\S+');

  // Returns list of (url, useMusic) from pasted share text.
  // € at end of entry → original has no music → useMusic=false
  static List<({String url, bool useMusic})> parse(String text) {
    final matches = _urlRegex.allMatches(text).toList();
    final result = <({String url, bool useMusic})>[];

    for (var i = 0; i < matches.length; i++) {
      var url = matches[i].group(0)!;
      // strip trailing non-URL chars (spaces, slashes already included)
      url = url.replaceAll(RegExp(r'[^\w/\-_~%]+$'), '');

      final segEnd =
          i + 1 < matches.length ? matches[i + 1].start : text.length;
      final segment = text.substring(matches[i].start, segEnd);
      final useMusic = !segment.contains('€');
      result.add((url: url, useMusic: useMusic));
    }
    return result;
  }
}
