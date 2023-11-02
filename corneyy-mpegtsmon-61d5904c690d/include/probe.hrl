-record(probe_state, {
  status=unknown,         % overall status of the probe
  dups_htp=0,             % dup's detected by probe
  dups_pth=0,             % dup's detected by host
  host_packet_lost=0,     % lost of packet, sent by the host
  probe_packet_lost=0     % lost of packet, sent by the probe
}).