// Test double: no USB access. Exercises the actual helper's session logic.
#include <libmtp.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
static const char *mode(void) { const char *m=getenv("TEST_MTP_MODE"); return m?m:"ok"; }
static void trace(const char *event) {
  const char *path=getenv("TEST_MTP_TRACE");
  if(path) { FILE *f=fopen(path,"a"); if(f) { fprintf(f,"%s\n",event); fclose(f); } }
}
void LIBMTP_Init(void) {}
LIBMTP_error_number_t LIBMTP_Detect_Raw_Devices(LIBMTP_raw_device_t **r,int *n) {
  *n=1; *r=calloc(1,sizeof(**r)); (*r)->device_entry.vendor_id=!strcmp(mode(),"other")?0x1234:0x057e;
  (*r)->device_entry.product_id=0x3000; (*r)->bus_location=42; (*r)->devnum=7; return LIBMTP_ERROR_NONE;
}
LIBMTP_mtpdevice_t *LIBMTP_Open_Raw_Device_Uncached(LIBMTP_raw_device_t *r) { (void)r; trace("open"); return calloc(1,sizeof(LIBMTP_mtpdevice_t)); }
int LIBMTP_Get_Storage(LIBMTP_mtpdevice_t *d,int sort) {
  (void)sort; d->storage=calloc(1,sizeof(*d->storage)); d->storage->id=5;
  d->storage->StorageDescription=strdup(!strcmp(mode(),"nand")?"6: NAND install":"5: SD Card install");
  if(!strcmp(mode(),"browser")) {
    LIBMTP_devicestorage_t *sd=calloc(1,sizeof(*sd)),*ro=calloc(1,sizeof(*ro));
    sd->id=1;sd->StorageDescription=strdup("1: SD Card");sd->AccessCapability=0;
    ro->id=9;ro->StorageDescription=strdup("7: Saves");ro->AccessCapability=0;
    d->storage->next=sd;sd->next=ro;
  }
  d->storage->FreeSpaceInBytes=100000000000ULL; d->storage->MaxCapacity=200000000000ULL; return 0;
}
char *LIBMTP_Get_Serialnumber(LIBMTP_mtpdevice_t *d) { (void)d; return strdup("test-switch"); }
void LIBMTP_Release_Device(LIBMTP_mtpdevice_t *d) { trace("close"); LIBMTP_devicestorage_t *s=d->storage;while(s){LIBMTP_devicestorage_t *next=s->next;free(s->StorageDescription);free(s);s=next;}free(d); }
LIBMTP_error_t *LIBMTP_Get_Errorstack(LIBMTP_mtpdevice_t *d) { (void)d; return NULL; }
void LIBMTP_Clear_Errorstack(LIBMTP_mtpdevice_t *d) { (void)d; }
LIBMTP_file_t *LIBMTP_new_file_t(void) { return calloc(1,sizeof(LIBMTP_file_t)); }
void LIBMTP_destroy_file_t(LIBMTP_file_t *f) { free(f->filename); free(f); }
static int browser_upload(LIBMTP_file_t *,int);
int LIBMTP_Send_File_From_File_Descriptor(LIBMTP_mtpdevice_t *d,int fd,LIBMTP_file_t *f,LIBMTP_progressfunc_t cb,const void *data) {
  (void)d; (void)fd; trace("send");
  if(f->storage_id==5) { if(f->parent_id!=UINT32_MAX || !f->filename) abort(); }
  else if(browser_upload(f,fd)) return -1;
  if(!strcmp(mode(),"fail")) return -1;
  if(!strcmp(mode(),"cancel")) {
    for(int i=0;i<500;++i) { usleep(10000); if(cb((uint64_t)i,f->filesize,data)) return -1; }
  }
  if(cb(f->filesize,f->filesize,data)) return -1;
  return 0;
}

typedef struct { uint32_t id, sid, parent; int folder; char *name; char *data; size_t size; } Node;
static Node nodes[256];
static uint32_t next_id=110;
static Node *node(uint32_t id) { for(int i=0;i<256;++i) if(nodes[i].id==id) return &nodes[i]; return NULL; }
static Node *add_node(uint32_t id,uint32_t sid,uint32_t parent,const char *name,int folder) {
  for(int i=0;i<256;++i) if(!nodes[i].id) { nodes[i]=(Node){.id=id,.sid=sid,.parent=parent,.folder=folder,.name=strdup(name)}; return &nodes[i]; }
  abort();
}
static void init_nodes(void) {
  if(node(101)) return;
  Node *f=add_node(101,1,UINT32_MAX,"hello.txt",0); f->data=strdup("fixture bytes");f->size=strlen(f->data);
  add_node(102,1,UINT32_MAX,"empty",1); add_node(103,1,UINT32_MAX,"full",1);
  add_node(104,1,103,"child.txt",0); add_node(105,9,UINT32_MAX,"save.dat",0);
}
static LIBMTP_file_t *metadata(Node *n) {
  if(!n) return NULL;
  LIBMTP_file_t *f=LIBMTP_new_file_t();f->item_id=n->id;f->storage_id=n->sid;f->parent_id=n->parent;f->filename=strdup(n->name);f->filesize=n->size;f->filetype=n->folder?LIBMTP_FILETYPE_FOLDER:LIBMTP_FILETYPE_UNKNOWN;return f;
}
LIBMTP_file_t *LIBMTP_Get_Filemetadata(LIBMTP_mtpdevice_t *d,uint32_t id) { (void)d;init_nodes();return metadata(node(id)); }
LIBMTP_file_t *LIBMTP_Get_Files_And_Folders(LIBMTP_mtpdevice_t *d,uint32_t sid,uint32_t parent) {
  (void)d;init_nodes();LIBMTP_file_t *head=NULL,**tail=&head;
  for(int i=0;i<256;++i) if(nodes[i].id && nodes[i].sid==sid && nodes[i].parent==parent) { *tail=metadata(&nodes[i]);tail=&(*tail)->next; }
  return head;
}
uint32_t LIBMTP_Create_Folder(LIBMTP_mtpdevice_t *d,char *name,uint32_t parent,uint32_t sid) { (void)d;init_nodes();uint32_t id=next_id++;add_node(id,sid,parent,name,1);trace("mkdir");return id; }
int LIBMTP_Set_Object_Filename(LIBMTP_mtpdevice_t *d,uint32_t id,char *name) { (void)d;Node *n=node(id);if(!n)return -1;free(n->name);n->name=strdup(name);trace("rename");return 0; }
int LIBMTP_Delete_Object(LIBMTP_mtpdevice_t *d,uint32_t id) { (void)d;Node *n=node(id);if(!n)return -1;free(n->name);free(n->data);memset(n,0,sizeof(*n));trace("delete");return 0; }
int LIBMTP_Get_File_To_File_Descriptor(LIBMTP_mtpdevice_t *d,uint32_t id,int fd,LIBMTP_progressfunc_t cb,const void *data) { (void)d;Node *n=node(id);if(!n)return -1;if(n->size && write(fd,n->data,n->size)!=(ssize_t)n->size)return -1;return cb(n->size,n->size,data)?-1:0; }
static int browser_upload(LIBMTP_file_t *f,int fd) {
  init_nodes();Node *n=add_node(next_id++,f->storage_id,f->parent_id,f->filename,0);n->size=(size_t)f->filesize;n->data=calloc(n->size+1,1);
  if(n->size && read(fd,n->data,n->size)!=(ssize_t)n->size)return -1;return 0;
}

LIBMTP_file_t *LIBMTP_SwitchDrop_List(LIBMTP_mtpdevice_t *d,uint32_t sid,uint32_t parent) { return LIBMTP_Get_Files_And_Folders(d,sid,parent); }
