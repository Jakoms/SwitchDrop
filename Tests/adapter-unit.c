#include <libmtp.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
typedef struct { int unused; } PTPParams;
typedef union { uint16_t u16; uint32_t u32; uint64_t u64; char *str; } PTPPropertyValue;
typedef struct { uint16_t property,datatype; uint32_t ObjectHandle; PTPPropertyValue propval; } MTPProperties;
#define PTP_RC_OK 0x2001
#define PTP_OFC_Association 0x3001
#define PTP_DTC_UINT64 8
#define PTP_OPC_StorageID 0xDC01
#define PTP_OPC_ObjectFormat 0xDC02
#define PTP_OPC_ObjectSize 0xDC04
#define PTP_OPC_ObjectFileName 0xDC07
#define PTP_OPC_ParentObject 0xDC0B
static int unsupported;
LIBMTP_file_t *LIBMTP_new_file_t(void) { return calloc(1,sizeof(LIBMTP_file_t)); }
void LIBMTP_destroy_file_t(LIBMTP_file_t*f) {free(f->filename);free(f);}
LIBMTP_file_t *LIBMTP_Get_Files_And_Folders(LIBMTP_mtpdevice_t*d,uint32_t s,uint32_t p) {(void)d;(void)s;(void)p;LIBMTP_file_t*f=LIBMTP_new_file_t();f->item_id=777;return f;}
static void fill(MTPProperties *p,uint32_t id,uint32_t sid,uint32_t parent,const char *name,int folder,uint64_t size) {
  p[0]=(MTPProperties){PTP_OPC_StorageID,6,id,{.u32=sid}};
  p[1]=(MTPProperties){PTP_OPC_ParentObject,6,id,{.u32=parent}};
  p[2]=(MTPProperties){PTP_OPC_ObjectFileName,0xffff,id,{.str=strdup(name)}};
  p[3]=(MTPProperties){PTP_OPC_ObjectFormat,4,id,{.u16=folder?PTP_OFC_Association:0x3000}};
  p[4]=(MTPProperties){PTP_OPC_ObjectSize,PTP_DTC_UINT64,id,{.u64=size}};
}
static uint16_t ptp_mtp_getobjectproplist_generic(PTPParams *params,uint32_t query,uint32_t formats,uint32_t properties,uint32_t groups,uint32_t depth,MTPProperties **out,int *count) {
  (void)params;assert(query==1 && formats==0 && properties==UINT32_MAX && groups==0 && depth==1);
  if(unsupported)return 0x2005;
  *count=25;*out=calloc(25,sizeof(**out));
  fill(*out,1,1,UINT32_MAX,"storage root",1,0);
  fill(*out+5,100,1,UINT32_MAX,"large.bin",0,UINT64_C(8589934599));
  fill(*out+10,101,1,0,"folder",1,0);
  fill(*out+15,200,9,UINT32_MAX,"other storage",0,42);
  fill(*out+20,201,1,101,"grandchild",0,42);
  return PTP_RC_OK;
}
static void ptp_destroy_object_prop_list(MTPProperties*p,int count) {for(int i=0;i<count;i++)if(p[i].property==PTP_OPC_ObjectFileName)free(p[i].propval.str);free(p);}
#include "../Source/libmtp-dbi-extension.inc"
int main(void) {
  LIBMTP_mtpdevice_t d={0};LIBMTP_file_t *f=LIBMTP_SwitchDrop_List(&d,1,UINT32_MAX);int count=0,large=0,folder=0;
  while(f){LIBMTP_file_t*next=f->next;count++;assert(f->storage_id==1);if(f->item_id==100){assert(f->filesize==UINT64_C(8589934599));large=1;}if(f->item_id==101){assert(f->filetype==LIBMTP_FILETYPE_FOLDER);folder=1;}LIBMTP_destroy_file_t(f);f=next;}
  assert(count==2 && large && folder);unsupported=1;f=LIBMTP_SwitchDrop_List(&d,1,UINT32_MAX);assert(f->item_id==777);LIBMTP_destroy_file_t(f);
  puts("Adapter tests passed: DBI root query, direct children, storage isolation, 64-bit size, root exclusion, unsupported-operation fallback.");return 0;
}
