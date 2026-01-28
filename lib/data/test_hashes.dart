/// Test hashes for development and testing purposes.
/// These hashes are loaded during the loading phase and merged with
/// the actual threat hashes from the remote source.
///
/// Format: MD5 hashes (32 hex characters, lowercase)

class TestHashes {
  /// Returns a set of test hashes to be loaded for testing purposes
  static Set<String> getTestHashes() {
    return {
      '8d311b8ea91fc12e819cd17fb0277782',
      'd249abaee0a0a000a0481d2a2b4df21a',
      'b8e4fa91915438949b1b4ce702a0a11b',
    };
  }
}
