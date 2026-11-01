// Merge directories by name. Resolve file collisions explicitly within this upload only.
#include <CoreFoundation/CoreFoundation.h>
static int names_equal(const char *a,const char *b) {
  if(!a || !b)return 0;
  CFStringRef x=CFStringCreateWithCString(NULL,a,kCFStringEncodingUTF8);
  CFStringRef y=CFStringCreateWithCString(NULL,b,kCFStringEncodingUTF8);
  int equal=x && y ? CFStringCompare(x,y,kCFCompareCaseInsensitive|kCFCompareNonliteral)==kCFCompareEqualTo : !strcasecmp(a,b);
  if(x)CFRelease(x);if(y)CFRelease(y);return equal;
}
static LIBMTP_file_t *upload_child(LIBMTP_mtpdevice_t *d,uint32_t sid,uint32_t parent,const char *name,int *error) {
  *error=0;LIBMTP_Clear_Errorstack(d);
  LIBMTP_file_t *files=LIBMTP_SwitchDrop_List(d,sid,parent),*match=NULL;
  if(LIBMTP_Get_Errorstack(d)){destroy_files(files);*error=1;return NULL;}
  while(files) {
    LIBMTP_file_t *next=files->next;files->next=NULL;
    if(files->storage_id!=sid || !files->item_id || files->item_id==UINT32_MAX || files->item_id==sid || (files->parent_id!=parent && !(parent==UINT32_MAX && (files->parent_id==0 || files->parent_id==sid)))) {
      if(match)LIBMTP_destroy_file_t(match);match=NULL;*error=1;LIBMTP_destroy_file_t(files);destroy_files(next);break;
    }
    if(names_equal(files->filename,name)) {
      if(match){LIBMTP_destroy_file_t(match);match=NULL;*error=1;LIBMTP_destroy_file_t(files);destroy_files(next);break;}
      match=files;
    } else LIBMTP_destroy_file_t(files);
    files=next;
  }
  return match;
}
typedef enum { UPLOAD_STOP,UPLOAD_SKIP,UPLOAD_KEEP,UPLOAD_REPLACE } UploadChoice;
typedef struct { size_t copied,merged,replaced,skipped,kept;UploadChoice policy; } UploadStats;
static uint64_t upload_token=0;
static int upload_conflict(LIBMTP_mtpdevice_t *d,const char *path,int source_folder,uint64_t size,LIBMTP_file_t *existing,UploadStats *stats,UploadChoice *choice) {
  int file_pair=!source_folder && existing->filetype!=LIBMTP_FILETYPE_FOLDER;
  if(file_pair && stats->policy!=UPLOAD_STOP){*choice=stats->policy;return 0;}
  uint64_t token=++upload_token;
  fprintf(out,"{\"type\":\"uploadconflict\",\"token\":\"%llu\",\"sourceFolder\":%s,\"destinationFolder\":%s,\"sourceSize\":%llu,\"destinationSize\":%llu,\"path\":",(unsigned long long)token,source_folder?"true":"false",existing->filetype==LIBMTP_FILETYPE_FOLDER?"true":"false",(unsigned long long)size,(unsigned long long)existing->filesize);
  quoted(path);fprintf(out,",\"name\":");quoted(existing->filename);fprintf(out,"}\n");fflush(out);
  uint32_t network;
  if(read_exact(&network,4)){cancelled=1;return 1;}
  size_t length=ntohl(network);
  if(!length || length>256)return op_error(d,"Invalid upload conflict response.");
  char data[257];if(read_exact(data,length)){cancelled=1;return 1;}data[length]=0;
  if(data[length-1]!=0)return op_error(d,"Invalid upload conflict response.");
  char *args[4];size_t pos=0;
  for(int i=0;i<4;i++){if(pos>=length)return op_error(d,"Invalid upload conflict response.");args[i]=data+pos;pos+=strlen(args[i])+1;}
  if(pos!=length || strcmp(args[0],"uploadchoice") || strtoull(args[1],NULL,10)!=token)return op_error(d,"Upload conflict confirmation expired.");
  if(!strcmp(args[2],"skip"))*choice=UPLOAD_SKIP;
  else if(!strcmp(args[2],"keep"))*choice=UPLOAD_KEEP;
  else if(!strcmp(args[2],"replace") && file_pair)*choice=UPLOAD_REPLACE;
  else if(!strcmp(args[2],"stop")){cancelled=1;return 1;}
  else return op_error(d,"This type conflict cannot be replaced. Rename or remove the destination explicitly.");
  if(file_pair && !strcmp(args[3],"all"))stats->policy=*choice;
  return 0;
}
static char *upload_unique_name(LIBMTP_mtpdevice_t *d,uint32_t sid,uint32_t parent,const char *name,int folder,int temporary) {
  for(unsigned int i=2;i<10000;i++) {
    char *candidate=NULL;
    if(temporary) {
      if(asprintf(&candidate,".switchdrop-%s-%d-%llu-%u.tmp",name,getpid(),(unsigned long long)upload_token,i)<0)return NULL;
    } else {
      const char *ext=folder?NULL:strrchr(name,'.');
      if(ext==name)ext=NULL;
      if(ext){if(asprintf(&candidate,"%.*s (%u)%s",(int)(ext-name),name,i,ext)<0)return NULL;}
      else if(asprintf(&candidate,"%s (%u)",name,i)<0)return NULL;
    }
    if(!valid_name(candidate)){free(candidate);return NULL;}
    int error=0;LIBMTP_file_t *existing=upload_child(d,sid,parent,candidate,&error);
    int occupied=existing!=NULL;
    if(existing)LIBMTP_destroy_file_t(existing);
    if(error){free(candidate);return NULL;}
    if(!occupied)return candidate;
    free(candidate);
  }
  return NULL;
}
static int upload_file(LIBMTP_mtpdevice_t *d,uint32_t sid,uint32_t parent,const char *path,const char *name,uint32_t *object) {
  int fd=open(path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW);struct stat st;
  if(fd<0 || fstat(fd,&st) || !S_ISREG(st.st_mode)){if(fd>=0)close(fd);return op_error(d,"Cannot read the local file.");}
  LIBMTP_file_t *f=LIBMTP_new_file_t();
  f->filename=strdup(name);f->filesize=(uint64_t)st.st_size;f->filetype=LIBMTP_FILETYPE_UNKNOWN;
  f->storage_id=sid;f->parent_id=parent;f->modificationdate=st.st_mtime;
  fs_start(path,f->filesize);
  int rc=LIBMTP_Send_File_From_File_Descriptor(d,fd,f,progress,NULL);
  *object=f->item_id;close(fd);LIBMTP_destroy_file_t(f);
  return rc?op_error(d,"Upload failed. A partial item may remain on the Switch."):0;
}
static int replace_upload_file(LIBMTP_mtpdevice_t *d,uint32_t sid,uint32_t parent,const char *path,LIBMTP_file_t *existing) {
  char *staged=upload_unique_name(d,sid,parent,"upload",0,1),*backup=upload_unique_name(d,sid,parent,"backup",0,1);
  if(!staged || !backup){free(staged);free(backup);return op_error(d,"Cannot create a safe temporary filename.");}
  uint32_t staged_id=0;
  int rc=upload_file(d,sid,parent,path,staged,&staged_id);
  if(rc || cancelled){free(staged);free(backup);return 1;} // Original remains untouched if transfer fails or is cancelled.
  int error=0;LIBMTP_file_t *current=upload_child(d,sid,parent,existing->filename,&error);
  if(error || !current || current->item_id!=existing->item_id || current->filetype==LIBMTP_FILETYPE_FOLDER || current->filesize!=existing->filesize || strcmp(current->filename,existing->filename)) {
    if(current)LIBMTP_destroy_file_t(current);free(staged);free(backup);
    return op_error(d,"Destination changed during upload. The new file was kept under a temporary name; the destination was not replaced.");
  }
  LIBMTP_destroy_file_t(current);
  if(LIBMTP_Set_Object_Filename(d,existing->item_id,backup)){free(staged);free(backup);return op_error(d,"Could not prepare replacement. The original file and the staged upload were preserved.");}
  if(cancelled) {
    int restore=LIBMTP_Set_Object_Filename(d,existing->item_id,existing->filename);free(staged);free(backup);
    return restore?op_error(d,"Replacement failed. The old file is under a .switchdrop-backup name and the new file is under a .switchdrop-upload name."):1;
  }
  if(LIBMTP_Set_Object_Filename(d,staged_id,existing->filename)) {
    int restore=LIBMTP_Set_Object_Filename(d,existing->item_id,existing->filename);
    free(staged);free(backup);
    return op_error(d,restore?"Replacement failed. The old file is under a .switchdrop-backup name and the new file is under a .switchdrop-upload name.":"Replacement failed. The original name was restored; the staged upload was preserved.");
  }
  if(cancelled){free(staged);free(backup);return 1;}
  rc=LIBMTP_Delete_Object(d,existing->item_id);
  free(staged);free(backup);
  return rc?op_error(d,"The new file was copied, but the old backup could not be removed. A .switchdrop-backup file remains."):0;
}
static int upload_path_as(LIBMTP_mtpdevice_t *d,uint32_t sid,uint32_t parent,const char *path,int depth,const char *override,UploadStats *stats) {
  if(cancelled)return 1;
  if(depth>64)return op_error(d,"Folder nesting is too deep.");
  struct stat st;
  if(lstat(path,&st) || (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)))return op_error(d,"Only regular files and folders can be uploaded; symbolic links are skipped.");
  const char *base=strrchr(path,'/');base=base?base+1:path;
  const char *name=override?override:base;int source_folder=S_ISDIR(st.st_mode);
  if(!valid_name(name))return op_error(d,"The name contains characters unsupported by the SD card.");
  int error=0;LIBMTP_file_t *existing=upload_child(d,sid,parent,name,&error);
  if(error)return op_error(d,"Could not unambiguously read the destination folder.");
  uint32_t folder=0;
  if(existing && source_folder && existing->filetype==LIBMTP_FILETYPE_FOLDER) {
    folder=existing->item_id;stats->merged++; // Reuse the destination directory; never delete its other children.
    LIBMTP_destroy_file_t(existing);existing=NULL;
  } else if(existing) {
    UploadChoice choice=UPLOAD_STOP;int rc=upload_conflict(d,path,source_folder,(uint64_t)st.st_size,existing,stats,&choice);
    if(rc){LIBMTP_destroy_file_t(existing);return rc;}
    if(choice==UPLOAD_SKIP){stats->skipped++;LIBMTP_destroy_file_t(existing);return 0;}
    if(choice==UPLOAD_KEEP) {
      char *unique=upload_unique_name(d,sid,parent,name,source_folder,0);LIBMTP_destroy_file_t(existing);
      if(!unique)return op_error(d,"Cannot create a unique destination filename.");
      rc=upload_path_as(d,sid,parent,path,depth,unique,stats);free(unique);if(!rc)stats->kept++;return rc;
    }
    rc=replace_upload_file(d,sid,parent,path,existing);LIBMTP_destroy_file_t(existing);
    if(!rc){stats->copied++;stats->replaced++;}return rc;
  }
  if(source_folder) {
    DIR *dir=opendir(path);if(!dir)return op_error(d,"Cannot read the local folder.");
    if(!folder)folder=LIBMTP_Create_Folder(d,(char*)name,parent,sid);
    if(!folder){closedir(dir);return op_error(d,"Could not create the destination folder.");}
    int rc=0;struct dirent *entry;
    while(!cancelled && (entry=readdir(dir))) {
      if(!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..") || !strcmp(entry->d_name,".DS_Store"))continue;
      char *child=NULL;if(asprintf(&child,"%s/%s",path,entry->d_name)<0){rc=op_error(d,"Cannot read the local folder.");break;}
      rc=upload_path_as(d,sid,folder,child,depth+1,NULL,stats);free(child);if(rc)break;
    }
    closedir(dir);return rc;
  }
  uint32_t object=0;int rc=upload_file(d,sid,parent,path,name,&object);if(!rc)stats->copied++;return rc;
}
