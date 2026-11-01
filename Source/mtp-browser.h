// File operations share the existing libmtp session; no USB reopen between commands.
#include <dirent.h>
#include <limits.h>
LIBMTP_file_t *LIBMTP_SwitchDrop_List(LIBMTP_mtpdevice_t *,uint32_t,uint32_t);
static const char *plain_label(const char *s) {
  if(!s) return "";
  while(*s==' ' || (*s>='0' && *s<='9') || *s==':') ++s;
  return s;
}
static LIBMTP_devicestorage_t *find_storage(LIBMTP_mtpdevice_t *d,uint32_t id) {
  for(LIBMTP_devicestorage_t *s=d->storage;s;s=s->next) if(s->id==id) return s;
  return NULL;
}
static int any_install_volume(const char *name) {
  return install_volume(name) || !strcasecmp(plain_label(name),"NAND install");
}
static int writable_storage(LIBMTP_devicestorage_t *s) {
  return s && !strcasecmp(plain_label(s->StorageDescription),"SD Card") && s->AccessCapability==0;
}
static void emit_storages(LIBMTP_mtpdevice_t *d) {
  for(LIBMTP_devicestorage_t *s=d->storage;s;s=s->next) {
    fprintf(out,"{\"type\":\"storage\",\"id\":%u,\"writable\":%s,\"install\":%s,\"free\":%llu,\"capacity\":%llu,\"label\":",s->id,writable_storage(s)?"true":"false",any_install_volume(s->StorageDescription)?"true":"false",(unsigned long long)s->FreeSpaceInBytes,(unsigned long long)s->MaxCapacity);
    quoted(s->StorageDescription); fprintf(out,"}\n");
  }
  fflush(out);
}
static int op_error(LIBMTP_mtpdevice_t *d,const char *text) { errors(d); message("operror",text); return 1; }
static void destroy_files(LIBMTP_file_t *f) { while(f) { LIBMTP_file_t *next=f->next; f->next=NULL; LIBMTP_destroy_file_t(f); f=next; } }
static LIBMTP_file_t *checked_object(LIBMTP_mtpdevice_t *d,uint32_t storage,uint32_t object) {
  if(!object || object==UINT32_MAX || object==storage) return NULL;
  LIBMTP_file_t *f=LIBMTP_Get_Filemetadata(d,object);
  if(f && f->storage_id!=storage) { LIBMTP_destroy_file_t(f); return NULL; }
  return f;
}
static int checked_parent(LIBMTP_mtpdevice_t *d,uint32_t storage,uint32_t parent) {
  if(parent==UINT32_MAX) return 1;
  LIBMTP_file_t *f=checked_object(d,storage,parent);
  int ok=f && f->filetype==LIBMTP_FILETYPE_FOLDER;
  if(f) LIBMTP_destroy_file_t(f);
  return ok;
}
static int valid_name(const char *s) {
  if(!s || !*s || !strcmp(s,".") || !strcmp(s,"..") || strlen(s)>240) return 0;
  for(const unsigned char *p=(const unsigned char*)s;*p;++p) if(*p<32 || strchr("/\\:*?\"<>|",*p)) return 0;
  return s[strlen(s)-1]!='.' && s[strlen(s)-1]!=' ';
}
// No implicit overwrite, including case-only collisions on FAT/exFAT.
static int collision(LIBMTP_mtpdevice_t *d,uint32_t storage,uint32_t parent,const char *name,uint32_t except) {
  LIBMTP_Clear_Errorstack(d);
  LIBMTP_file_t *files=LIBMTP_SwitchDrop_List(d,storage,parent);
  if(LIBMTP_Get_Errorstack(d)) { destroy_files(files); return -1; }
  int found=0;
  for(LIBMTP_file_t *f=files;f;f=f->next) if(f->item_id!=except && f->filename && !strcasecmp(f->filename,name)) { found=1; break; }
  destroy_files(files); return found;
}
static void fs_start(const char *name,uint64_t size) {
  current_index=-1; last_progress=0;
  fprintf(out,"{\"type\":\"fsstart\",\"size\":%llu,\"name\":",(unsigned long long)size); quoted(name); fprintf(out,"}\n"); fflush(out);
}
static int upload_path(LIBMTP_mtpdevice_t *d,uint32_t storage,uint32_t parent,const char *path,int depth) {
  if(cancelled) return 1;
  if(depth>64) return op_error(d,"Folder nesting is too deep.");
  struct stat st;
  if(lstat(path,&st) || (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode))) return op_error(d,"Only regular files and folders can be uploaded; symbolic links are skipped.");
  const char *name=strrchr(path,'/'); name=name?name+1:path;
  if(!valid_name(name)) return op_error(d,"The name contains characters unsupported by the SD card.");
  int exists=collision(d,storage,parent,name,0);
  if(exists) return op_error(d,exists>0?"An item with this name already exists. Rename it first.":"Could not check the destination folder.");
  if(S_ISDIR(st.st_mode)) {
    DIR *dir=opendir(path); if(!dir) return op_error(d,"Cannot read the local folder.");
    uint32_t folder=LIBMTP_Create_Folder(d,(char*)name,parent,storage);
    if(!folder) { closedir(dir); return op_error(d,"Could not create the destination folder."); }
    int rc=0; struct dirent *entry;
    while(!cancelled && (entry=readdir(dir))) {
      if(!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..") || !strcmp(entry->d_name,".DS_Store")) continue;
      char *child=NULL;
      if(asprintf(&child,"%s/%s",path,entry->d_name)<0) { rc=1; break; }
      rc=upload_path(d,storage,folder,child,depth+1); free(child);
      if(rc) break;
    }
    closedir(dir); return rc;
  }
  int fd=open(path,O_RDONLY|O_NONBLOCK);
  if(fd<0 || fstat(fd,&st) || !S_ISREG(st.st_mode)) { if(fd>=0) close(fd); return op_error(d,"Cannot read the local file."); }
  LIBMTP_file_t *f=LIBMTP_new_file_t();
  f->filename=strdup(name); f->filesize=(uint64_t)st.st_size; f->filetype=LIBMTP_FILETYPE_UNKNOWN;
  f->storage_id=storage; f->parent_id=parent; f->modificationdate=st.st_mtime;
  fs_start(name,f->filesize);
  int rc=LIBMTP_Send_File_From_File_Descriptor(d,fd,f,progress,NULL);
  close(fd); LIBMTP_destroy_file_t(f);
  return rc?op_error(d,"Upload failed. A partial item may remain on the Switch."):0;
}
#include "mtp-delete.h"
static int browser_command(LIBMTP_mtpdevice_t *d,int count,char **args) {
  if(count<3) return op_error(d,"Invalid file operation.");
  uint32_t sid=(uint32_t)strtoul(args[1],NULL,10), id=(uint32_t)strtoul(args[2],NULL,10);
  LIBMTP_devicestorage_t *storage=find_storage(d,sid);
  if(!storage || any_install_volume(storage->StorageDescription)) return op_error(d,"This storage is not browsable. Use the install queue instead.");
  if(strcmp(args[0],"deleteplan") && strcmp(args[0],"deletecommit") && strcmp(args[0],"deletecancel")) free_delete_plan(&pending_delete);
  LIBMTP_Clear_Errorstack(d);
  if(!strcmp(args[0],"list") && count==3) {
    if(!checked_parent(d,sid,id)) return op_error(d,"The destination folder is no longer available.");
    message("listbegin","");
    LIBMTP_file_t *files=LIBMTP_SwitchDrop_List(d,sid,id);
    if(LIBMTP_Get_Errorstack(d)) { destroy_files(files); return op_error(d,"Could not read this folder."); }
    for(LIBMTP_file_t *f=files;f;f=f->next) {
      fprintf(out,"{\"type\":\"entry\",\"id\":%u,\"parent\":%u,\"storage\":%u,\"folder\":%s,\"size\":%llu,\"modified\":%lld,\"name\":",f->item_id,f->parent_id,sid,f->filetype==LIBMTP_FILETYPE_FOLDER?"true":"false",(unsigned long long)f->filesize,(long long)f->modificationdate);
      quoted(f->filename); fprintf(out,"}\n");
    }
    fflush(out); destroy_files(files); return 0;
  }
  if(!strcmp(args[0],"download") && count==4) {
    LIBMTP_file_t *f=checked_object(d,sid,id);
    if(!f || f->filetype==LIBMTP_FILETYPE_FOLDER) { if(f) LIBMTP_destroy_file_t(f); return op_error(d,"Select a file to download."); }
    char *temp=NULL;
    if(asprintf(&temp,"%s.switchdrop-partial-%d",args[3],getpid())<0) { LIBMTP_destroy_file_t(f); return 1; }
    int fd=open(temp,O_WRONLY|O_CREAT|O_EXCL,0600);
    if(fd<0) { free(temp); LIBMTP_destroy_file_t(f); return op_error(d,"Cannot create the local file. Choose another location."); }
    fs_start(f->filename,f->filesize); LIBMTP_destroy_file_t(f);
    int rc=LIBMTP_Get_File_To_File_Descriptor(d,id,fd,progress,NULL);
    if(!rc && fsync(fd)) rc=-1;
    close(fd);
    if(!rc && link(temp,args[3])) rc=-1; // atomic no-overwrite commit
    unlink(temp); free(temp);
    return rc?op_error(d,"Download failed or the destination already exists. Existing files were not changed."):0;
  }
  if(!writable_storage(storage)) return op_error(d,"This storage is read-only in SwitchDrop. File changes are available on SD Card only.");
  if(!strcmp(args[0],"deleteplan") || !strcmp(args[0],"deletecommit") || !strcmp(args[0],"deletecancel")) return deletion_command(d,count,args,sid,id);
  if(!strcmp(args[0],"upload") && count>=4) {
    if(!checked_parent(d,sid,id)) return op_error(d,"The destination folder is no longer available.");
    for(int i=3;i<count && !cancelled;++i) if(upload_path(d,sid,id,args[i],0)) return 1;
    return 0;
  }
  if(!strcmp(args[0],"mkdir") && count==4) {
    if(!checked_parent(d,sid,id) || !valid_name(args[3])) return op_error(d,"Invalid folder or name.");
    if(collision(d,sid,id,args[3],0)) return op_error(d,"An item with this name already exists or the folder cannot be read.");
    return LIBMTP_Create_Folder(d,args[3],id,sid)?0:op_error(d,"Could not create the folder.");
  }
  LIBMTP_file_t *f=checked_object(d,sid,id);
  if(!f) return op_error(d,"The selected item is no longer available.");
  int rc=1;
  if(!strcmp(args[0],"rename") && count==4) {
    uint32_t parent=f->parent_id?f->parent_id:UINT32_MAX;
    if(!valid_name(args[3]) || collision(d,sid,parent,args[3],id)) rc=op_error(d,"Invalid name, duplicate name, or the folder cannot be read.");
    else rc=LIBMTP_Set_Object_Filename(d,id,args[3])?op_error(d,"Rename failed."):0;
  } else if(!strcmp(args[0],"delete") && count==3) {
    int nonempty=0;
    if(f->filetype==LIBMTP_FILETYPE_FOLDER) {
      LIBMTP_Clear_Errorstack(d);
      LIBMTP_file_t *children=LIBMTP_SwitchDrop_List(d,sid,id);
      nonempty=children!=NULL || LIBMTP_Get_Errorstack(d)!=NULL; destroy_files(children);
    }
    rc=nonempty?op_error(d,"Only empty folders can be deleted. Remove their contents explicitly first."):(LIBMTP_Delete_Object(d,id)?op_error(d,"Delete failed."):0);
  } else rc=op_error(d,"Unknown file operation.");
  LIBMTP_destroy_file_t(f); return rc;
}
