#include <erl_driver.h>
#include <ei.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <errno.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sys/types.h>
#include <fcntl.h>
#include <assert.h>


const int MPEGTS_SIZE = 188;
const int NULL_PID = 0x1FFF;

#define STD_PACKET_SIZE 1316
#define PID_COUNT (0x1FFF+1)

const int SYS_RECV_BUFF = ((5*65535)/STD_PACKET_SIZE+1)*STD_PACKET_SIZE;
const int BUFF_LIMIT = ((2*1024*1024)/STD_PACKET_SIZE+1)*STD_PACKET_SIZE;

const int NO_COUNTER = 0xFF;

enum {
CMD_OPEN = 1, CMD_ERRORS, CMD_SCRAMBLED, CMD_PACKET_COUNT, CMD_ACTIVE_ONCE,
CMD_PIDS_NUM, CMD_NULL_COUNT, CMD_PIDS,
CMD_RECORD_START, CMD_RECORD, CMD_RECORD_STOP, CMD_RECORD_STATUS,
CMD_TEI
} cmds;

ErlDrvTermData atom_udp;
ErlDrvTermData atom_record_ready;

static int mpegts_init(void) {
  atom_udp = driver_mk_atom("mpegts_udp");
  atom_record_ready = driver_mk_atom("mpegts_udp_record_ready");
  fprintf(stderr, "buffer limit %d\r\n", BUFF_LIMIT);
  return 0;
}

typedef struct s_mpegts{
  ErlDrvPort port;
  ErlDrvTermData port_term;
  ErlDrvTermData owner;
  int socket;
  uint8_t *buf;
  ssize_t buff_size;
  ssize_t buff_limit;
  ssize_t record_size;
  ssize_t record_limit;
  ssize_t len;
  uint8_t counters[PID_COUNT];
  uint32_t error_count;
  uint32_t scrambled;
  uint32_t packet_count;
  unsigned long timeout;
  uint32_t sync_error;
  uint32_t pids_num;
  uint32_t null_count;
  uint32_t tei;
  ErlDrvBinary* record;
  ssize_t (*input)(struct s_mpegts*);
} mpegts;

static ssize_t input_check_only(mpegts* d);
static ssize_t input_record(mpegts* d);

static ErlDrvData mpegts_drv_start(ErlDrvPort port, char *buff)
{
  mpegts* d = (mpegts *)driver_alloc(sizeof(mpegts));
  bzero(d, sizeof(mpegts));
  memset(d->counters, NO_COUNTER, PID_COUNT);
  d->port = port;
  d->port_term = driver_mk_port(d->port);
  d->owner = driver_caller(port);
  set_port_control_flags(port, PORT_CONTROL_FLAG_BINARY);
  d->buff_size = 2*SYS_RECV_BUFF;
  d->buff_limit = SYS_RECV_BUFF;
  d->record_size = BUFF_LIMIT+2*SYS_RECV_BUFF;
  d->record_limit = BUFF_LIMIT;
  d->timeout = 500;
  d->buf = (uint8_t *)driver_alloc(d->buff_size);
  d->len = 0;
  d->socket = -1;
  d->record=NULL;
  d->input=input_check_only;
  return (ErlDrvData)d;
}

static void mpegts_drv_stop(ErlDrvData handle)
{
  mpegts* d = (mpegts *)handle;
  if(d->socket != -1) {
    driver_select(d->port, (ErlDrvEvent)(long)d->socket, DO_READ, 0);
    close(d->socket);
  }
  d->socket = -1;
  if(NULL != d->record) driver_free_binary(d->record);
  // driver_free(d->buf);
  // driver_free(handle);
}

static ErlDrvSSizeT cmd_open(mpegts* d, char *buf, ErlDrvSizeT len, char **rbuf, ErlDrvSizeT rlen){
      int sock;
      int flags;
      struct sockaddr_in si;
      uint16_t port;
      if(len < 2) return 0;
      memcpy(&port, buf, 2);
      // fprintf(stderr, "Connecting to port %d\r\n", port);
      sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);

      int reuse = 1;
      if( setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) < 0 ) {
        driver_failure_posix(d->port, errno);
        close(sock);
        return 0;
      }

      bzero(&si, sizeof(si));
      si.sin_family = AF_INET;
      si.sin_port = port;
      si.sin_addr.s_addr = htonl(INADDR_ANY);
      if(len >= 6) {
        memcpy(&si.sin_addr.s_addr, buf+2, 4);
      }
      if(bind(sock, (struct sockaddr *)&si, sizeof(si)) == -1) {
        driver_failure_posix(d->port, errno);
        close(sock);
        return 0;
        // memcpy(*rbuf, "error", 5);
        // return 5;
      }

      if(len >= 6) {
        struct ip_mreq mreq;
        memcpy(&mreq.imr_multiaddr.s_addr, buf+2, 4);
        mreq.imr_interface.s_addr = htonl(INADDR_ANY);
        if(len >= 10) {
            memcpy(&mreq.imr_interface.s_addr, buf+6, 4);
        }

        if (setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) < 0) {
          perror("multicast join error\n");
          driver_failure_posix(d->port, errno);
          close(sock);
          d->socket = -1;
          return 0;
        }
      }

      int n = SYS_RECV_BUFF;
      if (setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &n, sizeof(n)) == -1) {
        fprintf(stderr, "Error set SO_RCVBUF: %d\r\n", n);
        // deal with failure, or ignore if you can live with the default size
        // driver_failure_posix(d->port, errno);
      }

      d->socket = sock;
      flags = fcntl(d->socket, F_GETFL);
      assert(flags >= 0);
      assert(!fcntl(d->socket, F_SETFL, flags | O_NONBLOCK));
      memcpy(*rbuf, "ok", 2);
      return 2;
 }

static ErlDrvSSizeT mpegts_drv_command(ErlDrvData handle, unsigned int command, char *buf, 
                   ErlDrvSizeT len, char **rbuf, ErlDrvSizeT rlen) {
  mpegts* d = (mpegts*) handle;
  
  switch(command) {
    case CMD_OPEN: return cmd_open(d, buf, len, rbuf, rlen);
    case CMD_ERRORS: {
      memcpy(*rbuf, &d->error_count, 4);
      d->error_count = 0;
      return 4;
    }
    case CMD_SCRAMBLED: {
      memcpy(*rbuf, &d->scrambled, 4);
      d->scrambled = 0;
      return 4;
    }
    case CMD_TEI: {
      memcpy(*rbuf, &d->tei, 4);
      d->tei = 0;
      return 4;
    }
    case CMD_PACKET_COUNT: {
      memcpy(*rbuf, &d->packet_count, 4);
      d->packet_count = 0;
      return 4;
    }
    case CMD_ACTIVE_ONCE: {
      driver_select(d->port, (ErlDrvEvent)(long)d->socket, DO_READ, 1);
      memcpy(*rbuf, "ok", 2);
      return 2;      
    }
    case CMD_PIDS_NUM: {
      memcpy(*rbuf, &d->pids_num, 4);
      return 4;
    }
    case CMD_NULL_COUNT: {
      memcpy(*rbuf, &d->null_count, 4);
      d->null_count = 0;
      return 4;
    }
    case CMD_RECORD_START: {                        // reset unsent or stopped record
      if(NULL==d->record){
        d->record = driver_alloc_binary(d->record_size);
      }
      d->input = input_record;
      d->len=0;
      return 0;
    }
    case CMD_RECORD: {
      *rbuf=(char*)d->record;
      d->record = NULL;
      return 0;
    }
    case CMD_RECORD_STOP: {
      d->input = input_check_only;
      d->len=0;
      return 0;
    }
    case CMD_RECORD_STATUS: {
      uint8_t status = input_record == d->input;
      memcpy(*rbuf, &status, 1);
      return 1;
    }
  }
  return -1;
}

static ErlDrvSSizeT mpegts_drv_call(ErlDrvData handle, unsigned int command, char *buf,
                   ErlDrvSizeT len, char **rbuf, ErlDrvSizeT rlen, unsigned int *flags) {
  mpegts* d = (mpegts*) handle;

  switch(command) {
    case CMD_PIDS: {
        int pos=0;
        ei_encode_version(*rbuf, &pos);
        if(rlen > 6+d->pids_num*(sizeof(long)+1)){ // lens of terms in external format
            ei_encode_list_header(*rbuf, &pos, d->pids_num);

            int pid=0;
            for(; pid<PID_COUNT;++pid){
                if(NO_COUNTER!=d->counters[pid])
                    ei_encode_long(*rbuf,&pos, pid);
            }

            ei_encode_empty_list(*rbuf, &pos);
        }else
            ei_encode_atom(*rbuf, &pos, "too_many_pids");
        return pos+1;
    }
  }
  return -1;
}

static void check_errors(mpegts *d, uint8_t *buf, ssize_t from)
{
  uint8_t *packet;
  for(packet = buf + from; packet < buf + d->len; packet += MPEGTS_SIZE) {
    if(packet[0] == 0x47) {
      d->packet_count++;
      uint16_t pid = ((packet[1] & 0x1F) << 8) | packet[2];

      if(NULL_PID==pid){
        ++d->null_count;
        continue;
      }

      d->tei += packet[1] >> 7;

      if(packet[3] >> 7) d->scrambled++;

      uint8_t counter = packet[3] & 0x0F;
      uint8_t expected = d->counters[pid];

      if(NO_COUNTER == expected) ++d->pids_num;
      else if(!(expected == counter || expected - counter==1 || (0==expected && 15==counter))) { // CC may not change under certain conditions
//        fprintf(stderr, "Pid: %5x %2d %2d %d %d\r\n", pid, d->counters[pid], counter,(int) d->len,(int) d->len % MPEGTS_SIZE);
        d->error_count++;
      }
      d->counters[pid] = (counter + 1) & 0x0F;
    }else{
        if(0==d->sync_error) fprintf(stderr, "Sync\r\n");
        d->sync_error = 1;
    }
  }
}

static ssize_t input_check_only(mpegts* d){
  ssize_t s;
  while((s = recvfrom(d->socket, d->buf+d->len, d->buff_size - d->len, 0, NULL, NULL)) > 0){
    d->len += s;
    if((d->len >= d->buff_limit)) {
        fprintf(stderr, "limit: %d\r\n", (int)d->len);
        check_errors(d, d->buf, 0);
        d->len=0;
        break;
    }
  }

  if(d->len>0) {
    check_errors(d, d->buf, 0);
    d->len=0;
  }

  return s;
}

static ssize_t input_record(mpegts* d){
  ssize_t plen = d->len;
  ssize_t s;

  while(
  (d->len < d->record_limit)
  && ((s = recvfrom(d->socket, d->record->orig_bytes+d->len, d->record_size - d->len, 0, NULL, NULL)) > 0)
  ){
    d->len += s;
  }

  check_errors(d, (uint8_t *)d->record->orig_bytes, plen);

  if(d->len >= d->record_limit) {
//      fprintf(stderr, "record ready: %d\r\n", (int)d->len);
      d->input = input_check_only;

      ErlDrvTermData reply[] = {
        ERL_DRV_ATOM, atom_record_ready,
        ERL_DRV_PORT, d->port_term,
        ERL_DRV_INT,  d->len,
        ERL_DRV_TUPLE, 3
      };
      erl_drv_output_term(d->port_term, reply, sizeof(reply) / sizeof(reply[0]));

      d->len = 0;
  }

  return s;
}

static void mpegts_drv_input(ErlDrvData handle, ErlDrvEvent event)
{
  mpegts* d = (mpegts*) handle;
  ssize_t s = d->input(d);

  if(s < 0 && errno != EAGAIN) {
    // driver_failure_posix(d->port, errno);    
    // driver_failure_atom(d->port, "failed_udp_read");
    ErlDrvTermData reply[] = {
      ERL_DRV_ATOM, driver_mk_atom("mpegts_closed"),
      ERL_DRV_PORT, driver_mk_port(d->port),
      ERL_DRV_INT, errno,
      ERL_DRV_TUPLE, 3
    };

    erl_drv_output_term(driver_mk_port(d->port), reply, sizeof(reply) / sizeof(reply[0]));
    // fprintf(stderr, "Failed read: %d, %d, %d\r\n", s, errno, d->len);
    d->len = 0;
  }
}

ErlDrvEntry mpegts_driver_entry = {
    mpegts_init,			/* F_PTR init, N/A */
    mpegts_drv_start,		/* L_PTR start, called when port is opened */
    mpegts_drv_stop,		/* F_PTR stop, called when port is closed */
    NULL,	    	/* F_PTR output, called when erlang has sent */
    mpegts_drv_input,			/* F_PTR ready_input, called when input descriptor ready */
    NULL,			/* F_PTR ready_output, called when output descriptor ready */
    "mpegts_udp",		/* char *driver_name, the argument to open_port */
    NULL,			/* F_PTR finish, called when unloaded */
    NULL,     /* void *handle */
    mpegts_drv_command,			/* F_PTR control, port_command callback */
    NULL,			/* F_PTR timeout, reserved */
    NULL,			/* F_PTR outputv, reserved */
    NULL,                      /* ready_async */
    NULL,                             /* flush */
    mpegts_drv_call,                  /* call */
    NULL,                             /* event */
    ERL_DRV_EXTENDED_MARKER,          /* ERL_DRV_EXTENDED_MARKER */
    ERL_DRV_EXTENDED_MAJOR_VERSION,   /* ERL_DRV_EXTENDED_MAJOR_VERSION */
    ERL_DRV_EXTENDED_MINOR_VERSION,   /* ERL_DRV_EXTENDED_MINOR_VERSION */
    ERL_DRV_FLAG_USE_PORT_LOCKING,     /* ERL_DRV_FLAGs */
    NULL,     /* void *handle2 */
    NULL,     /* process_exit */
    NULL      /* stop_select */
};

DRIVER_INIT(mpegts_udp) /* must match name in driver_entry */
{
    return &mpegts_driver_entry;
}
