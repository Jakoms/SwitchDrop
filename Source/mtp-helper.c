#define _DARWIN_C_SOURCE
#include <libmtp.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <assert.h>
#include <errno.h>
#include <arpa/inet.h>

static FILE *out;
static volatile sig_atomic_t cancelled = 0;
static double last_progress;
static int current_index;
static void stop(int s) { (void)s; cancelled = 1; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static void quoted(const char *s) {
  fputc('"', out);
  for (const unsigned char *p=(const unsigned char *)(s?s:""); *p; ++p) {
    if (*p=='"' || *p=='\\') { fputc('\\',out); fputc(*p,out); }
    else if (*p<32) fprintf(out,"\\u%04x",*p); else fputc(*p,out);
  }
  fputc('"',out);
}
static void message(const char *type, const char *msg) {
  fprintf(out,"{\"type\":\"%s\",\"message\":", type); quoted(msg); fprintf(out,"}\n"); fflush(out);
}
// Match the DBI virtual INSTALL volume only. Never fall back to SD Card or NAND.
static int install_volume(const char *s) {
  if (!s) return 0;
  while (*s==' ' || (*s>='0' && *s<='9') || *s==':') ++s;
  return !strcasecmp(s,"SD Card install");
}
static int supported(const char *s) {
  const char *e=strrchr(s,'.');
  return e && (!strcasecmp(e,".nsp") || !strcasecmp(e,".nsz") || !strcasecmp(e,".xci") || !strcasecmp(e,".xcz"));
}
static int progress(uint64_t sent, uint64_t total, const void *data) {
  (void)data;
  double t=now();
  if (t-last_progress>0.15 || sent==total) {
    fprintf(out,"{\"type\":\"progress\",\"index\":%d,\"sent\":%llu,\"total\":%llu}\n",current_index,(unsigned long long)sent,(unsigned long long)total);
    fflush(out); last_progress=t;
  }
  return cancelled?1:0;
}
static void errors(LIBMTP_mtpdevice_t *d) {
  for (LIBMTP_error_t *e=LIBMTP_Get_Errorstack(d); e; e=e->next)
    if (e->error_text) message("detail",e->error_text);
  LIBMTP_Clear_Errorstack(d);
}
static int transfer_files(LIBMTP_mtpdevice_t *d, uint32_t storage, char **paths, int count) {
  int result=0;
      for (int a=0;a<count && !cancelled;++a) {
        current_index=a; int fd=open(paths[a],O_RDONLY|O_NONBLOCK); struct stat st;
        if (fd<0 || fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_size<=0 || !supported(paths[a])) {
          if(fd>=0) close(fd); message("error","Файл недоступен, пуст или имеет неподдерживаемый формат. Очередь остановлена."); result=1; break;
        }
        LIBMTP_file_t *f=LIBMTP_new_file_t();
        const char *name=strrchr(paths[a],'/'); f->filename=strdup(name?name+1:paths[a]);
        f->filesize=(uint64_t)st.st_size; f->filetype=LIBMTP_FILETYPE_UNKNOWN;
        f->storage_id=storage; f->parent_id=UINT32_MAX; /* Explicit MTP storage root; DBI rejects object handle 0. */ f->modificationdate=st.st_mtime;
        fprintf(out,"{\"type\":\"start\",\"index\":%d,\"size\":%llu}\n",current_index,(unsigned long long)f->filesize); fflush(out);
        last_progress=0;
        int rc=cancelled?-1:LIBMTP_Send_File_From_File_Descriptor(d,fd,f,progress,NULL);
        close(fd); LIBMTP_destroy_file_t(f);
        if (rc!=0) { errors(d); if(!cancelled) message("error","DBI не подтвердил передачу. Проверьте экран Switch. Очередь остановлена."); result=1; break; }
        // Successful transport is not proof of successful title installation.
        fprintf(out,"{\"type\":\"sent\",\"index\":%d}\n",current_index); fflush(out);
      }
  return result;
}
static int read_exact(void *buf,size_t size);
#include "mtp-browser.h"
// Length-prefixed, NUL-separated UTF-8 arguments; filenames can contain newlines.
static int read_exact(void *buf, size_t size) {
  unsigned char *p=buf;
  while(size) {
    ssize_t n=read(STDIN_FILENO,p,size);
    if(n<0 && errno==EINTR) { if(cancelled) return -1; continue; }
    if(n<=0) return -1;
    p+=n; size-=(size_t)n;
  }
  return 0;
}
static int serve(LIBMTP_mtpdevice_t *d, LIBMTP_devicestorage_t *storage) {
  uint32_t install_id=storage?storage->id:0;
  message("ready","Switch подключён · MTP-сессия открыта");
  while(!cancelled) {
    uint32_t network;
    if(read_exact(&network,sizeof(network))) return 0;
    size_t length=ntohl(network);
    if(!length || length>4*1024*1024) { message("error","Некорректный размер команды MTP"); return 2; }
    char *data=malloc(length);
    if(!data || read_exact(data,length)) { free(data); return 2; }
    if(data[length-1]!=0) { free(data); message("error","Повреждённая команда MTP"); return 2; }
    int count=0;
    for(size_t i=0;i<length;++i) if(!data[i]) ++count;
    char **args=calloc((size_t)count,sizeof(*args));
    if(!args) { free(data); return 2; }
    size_t offset=0;
    for(int i=0;i<count;++i) { args[i]=data+offset; offset+=strlen(args[i])+1; }
    int result=0;
    if(count==1 && !strcmp(args[0],"quit")) { free(args); free(data); return 0; }
    if(count==1 && !strcmp(args[0],"ping")) {
      free(args);free(data);free_delete_plan(&pending_delete);
      if(LIBMTP_Get_Storage(d,LIBMTP_STORAGE_SORTBY_NOTSORTED)!=0) {
        errors(d);message("sessionlost","MTP-сессия больше не отвечает");return 1;
      }
      message("pong","");continue;
    }
    if(strcmp(args[0],"send")) {
      result=browser_command(d,count,args);
      free(args); free(data);
      if(cancelled) return 3;
      if(!result) message("fsdone","");
      continue;
    }
    storage=find_storage(d,install_id); // Get_Storage during ping replaces the storage list.
    if(count<3 || !storage || strtoul(args[1],NULL,10)!=storage->id || !install_volume(storage->StorageDescription)) {
      message("error","Выбрано неверное установочное хранилище"); result=2;
    } else {
      result=transfer_files(d,storage->id,args+2,count-2);
    }
    free(args); free(data);
    if(cancelled || result) return cancelled?3:result;
    message("batchdone","Передача завершена. Проверьте результат установки на экране DBI.");
  }
  return 3;
}
int main(int argc, char **argv) {
  // Keep libmtp chatter off the machine-readable event stream.
  out=fdopen(dup(STDOUT_FILENO),"w"); dup2(STDERR_FILENO,STDOUT_FILENO);
  signal(SIGUSR1,stop); signal(SIGTERM,stop); signal(SIGINT,stop);
  if (argc==2 && !strcmp(argv[1],"--self-test")) {
    assert(install_volume("5: SD Card install")); assert(install_volume("SD Card Install"));
    assert(!install_volume("1: SD Card")); assert(!install_volume("6: NAND install"));
    assert(!install_volume("SD Card Install backup")); assert(!install_volume(NULL));
    assert(supported("Игра.NSZ")); assert(!supported("test.zip"));
    LIBMTP_file_t *f=LIBMTP_new_file_t(); f->filesize=UINT64_C(8)*1024*1024*1024+7;
    assert(f->filesize==UINT64_C(8589934599)); LIBMTP_destroy_file_t(f);
    message("done","Backend tests passed: target isolation, extensions, 64-bit file size."); return 0;
  }
  int session=argc==2 && !strcmp(argv[1],"session");
  int scan=session || (argc==2 && !strcmp(argv[1],"scan"));
  if (!scan && !(argc>=8 && !strcmp(argv[1],"send"))) { message("error","Invalid arguments"); return 2; }
  LIBMTP_Init();
  LIBMTP_raw_device_t *raw=NULL; int count=0;
  LIBMTP_error_number_t err=LIBMTP_Detect_Raw_Devices(&raw,&count);
  if (err!=LIBMTP_ERROR_NONE && err!=LIBMTP_ERROR_NO_DEVICE_ATTACHED) { message("error","Не удалось получить список MTP-устройств. Закройте OpenMTP и подключите Switch заново."); free(raw); return 1; }
  int found=0, result=0;
  for (int i=0;i<count && !cancelled;++i) {
    // DBI uses Nintendo's USB vendor ID. Other USB devices are never opened.
    if (raw[i].device_entry.vendor_id!=0x057e) continue;
    if (!scan && (raw[i].bus_location!=strtoul(argv[2],NULL,10) || raw[i].devnum!=strtoul(argv[3],NULL,10) || raw[i].device_entry.product_id!=strtoul(argv[4],NULL,10))) continue;
    LIBMTP_mtpdevice_t *d=LIBMTP_Open_Raw_Device_Uncached(&raw[i]);
    if (!d) { message("detail","Switch найден, но занят или не отвечает. Закройте другие MTP-клиенты."); continue; }
    if (LIBMTP_Get_Storage(d,LIBMTP_STORAGE_SORTBY_NOTSORTED)!=0) { errors(d); LIBMTP_Release_Device(d); continue; }
    if(session) {
      LIBMTP_devicestorage_t *target=NULL;
      for(LIBMTP_devicestorage_t *s=d->storage;s;s=s->next) if(install_volume(s->StorageDescription)) { target=s; break; }
      char *serial=LIBMTP_Get_Serialnumber(d);
      fprintf(out,"{\"type\":\"device\",\"bus\":%u,\"dev\":%u,\"product\":%u,\"storage\":%u,\"free\":%llu,\"capacity\":%llu,\"label\":",raw[i].bus_location,raw[i].devnum,raw[i].device_entry.product_id,target?target->id:0,(unsigned long long)(target?target->FreeSpaceInBytes:0),(unsigned long long)(target?target->MaxCapacity:0));
      quoted(target?target->StorageDescription:""); fprintf(out,",\"serial\":"); quoted(serial); fprintf(out,"}\n"); fflush(out); free(serial);
      emit_storages(d);
      int rc=serve(d,target);
      LIBMTP_Release_Device(d); free(raw);
      if(cancelled) message("cancelled","Операция остановлена. Уже выполненные изменения сохранены.");
      else if(!rc) message("closed","MTP-сессия закрыта");
      return rc;
    }
    for (LIBMTP_devicestorage_t *s=d->storage; s; s=s->next) {
      if (!install_volume(s->StorageDescription)) continue;
      if (scan) {
        char *serial=LIBMTP_Get_Serialnumber(d);
        fprintf(out,"{\"type\":\"device\",\"bus\":%u,\"dev\":%u,\"product\":%u,\"storage\":%u,\"free\":%llu,\"capacity\":%llu,\"label\":",raw[i].bus_location,raw[i].devnum,raw[i].device_entry.product_id,s->id,(unsigned long long)s->FreeSpaceInBytes,(unsigned long long)s->MaxCapacity);
        quoted(s->StorageDescription); fprintf(out,",\"serial\":"); quoted(serial); fprintf(out,"}\n"); fflush(out); free(serial); ++found;
        if(session) {
          int rc=serve(d,s);
          LIBMTP_Release_Device(d); free(raw);
          if(cancelled) message("cancelled","Операция остановлена. Уже выполненные изменения сохранены.");
          else if(!rc) message("closed","MTP-сессия закрыта");
          return rc;
        }
        continue;
      }
      if (s->id!=strtoul(argv[5],NULL,10)) continue;
      char *serial=LIBMTP_Get_Serialnumber(d);
      int same=!strcmp(serial?serial:"",argv[6]); free(serial);
      if (!same) { message("error","Устройство изменилось. Обновите подключение."); result=1; break; }
      ++found;
      result=transfer_files(d,s->id,argv+7,argc-7);
      break;
    }
    LIBMTP_Release_Device(d);
    if (!scan && found) break;
  }
  free(raw);
  if (cancelled) { message("cancelled","Передача остановлена. Проверьте результат текущей установки в DBI."); return 3; }
  if (!found) { message("error","Switch с «SD Card install» не найден. В DBI запустите MTP Responder, подключите USB-кабель и закройте OpenMTP / Android File Transfer."); return 1; }
  if(!result) message("done",scan?"Подключение готово":"Передача завершена. Проверьте результат установки на экране DBI.");
  return result;
}
