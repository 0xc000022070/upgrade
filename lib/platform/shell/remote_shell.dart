String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String underSh(String script) => 'sh -c ${shellQuote(script)}';
