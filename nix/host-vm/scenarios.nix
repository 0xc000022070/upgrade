# nyx's firewall opens only 60000-61000 for mosh, and its own mosh-server climbs
# from 60001, so the guests share the top of that range.
{
  full = {
    sshPort = 2222;
    mosh.from = 60920;
    engine = true;
    herdr = true;
    codex = true;
  };

  bare = {
    sshPort = 2223;
    mosh.from = 60936;
  };

  herdr = {
    sshPort = 2224;
    mosh.from = 60952;
    herdr = true;
  };

  engine = {
    sshPort = 2225;
    mosh.from = 60968;
    engine = true;
  };

  declared = {
    sshPort = 2226;
    mosh.from = 60984;
    engine = true;
    declaredHooks = true;
  };
}
