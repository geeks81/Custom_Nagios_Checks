-record(bad_detail, {
  no_incoming=false,      % no incoming packets
  no_sync=false,          % incorrect sync byte
  no_AV=false,             % no audio&video PESs
  scrambled=false,
  tei=false
}).

-record(status, {
  is_ok=true,            % overall status of the stream
  byte_ps=0,              % bytes per seconds
  external_error=false,   % true == Transport Error Indicator field is 1
  scrambled=false,        % true == Transport Scrambling Control field not is 00
  discontinue_pi=0,       % CC discontinue counter per collection interval
  nullpid_pi=0,           % 0x1FFF pid per collection interval
  bad_detail=#bad_detail{}
}).