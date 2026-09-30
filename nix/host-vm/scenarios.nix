{
  full = {
    sshPort = 2222;
    mosh = {
      from = 60000;
      to = 61000;
      address = "127.0.0.1";
    };
    engine = true;
    herdr = true;
    codex = true;
  };

  bare = {
    sshPort = 2223;
    mosh.from = 61100;
  };

  herdr = {
    sshPort = 2224;
    mosh.from = 61120;
    herdr = true;
  };

  engine = {
    sshPort = 2225;
    mosh.from = 61140;
    engine = true;
  };

  declared = {
    sshPort = 2226;
    mosh.from = 61160;
    engine = true;
    declaredHooks = true;
  };
}
