// Two-phase deletion: read-only preview, then explicit commit in the same session.
#define DELETE_MAX_ITEMS 100000
#define DELETE_SET_SIZE 262144

typedef struct { uint32_t id,parent; int folder; uint64_t size; char *name; } DeleteItem;
typedef struct {
  uint32_t storage,root; uint64_t token,bytes; size_t count,capacity,files,folders;
  DeleteItem *items; uint32_t *seen;
} DeletePlan;
static DeletePlan pending_delete;
static uint64_t next_delete_token=1;
static void free_delete_plan(DeletePlan *p) {
  for(size_t i=0;i<p->count;i++) free(p->items[i].name);
  free(p->items);free(p->seen);memset(p,0,sizeof(*p));
}
static int collect_delete(LIBMTP_mtpdevice_t *d,DeletePlan *p,LIBMTP_file_t *f,int depth) {
  if(cancelled) return 1;
  if(depth>64 || p->count>=DELETE_MAX_ITEMS) return op_error(d,"The folder is too large or too deeply nested to delete safely.");
  if(!f || !f->item_id || f->item_id==UINT32_MAX || f->item_id==p->storage || f->storage_id!=p->storage || !f->filename)
    return op_error(d,"Deletion stopped: invalid item or storage.");
  size_t slot=((uint64_t)f->item_id*2654435761U)&(DELETE_SET_SIZE-1);
  while(p->seen[slot] && p->seen[slot]!=f->item_id) slot=(slot+1)&(DELETE_SET_SIZE-1);
  if(p->seen[slot]) return op_error(d,"Deletion stopped: the folder contains repeated object handles.");
  p->seen[slot]=f->item_id;
  int folder=f->filetype==LIBMTP_FILETYPE_FOLDER;
  if(folder) {
    LIBMTP_Clear_Errorstack(d);
    LIBMTP_file_t *children=LIBMTP_SwitchDrop_List(d,p->storage,f->item_id);
    if(LIBMTP_Get_Errorstack(d)) {destroy_files(children);return op_error(d,"Could not inspect the folder. Nothing was deleted.");}
    int rc=0;
    for(LIBMTP_file_t *c=children;c && !rc;c=c->next) {
      if(c->parent_id!=f->item_id) rc=op_error(d,"Deletion stopped: invalid parent folder.");
      else rc=collect_delete(d,p,c,depth+1);
    }
    destroy_files(children);if(rc)return rc;
  }
  if(p->count>=DELETE_MAX_ITEMS) return op_error(d,"The folder is too large or too deeply nested to delete safely.");
  if(p->count==p->capacity) {
    size_t capacity=p->capacity?p->capacity*2:64;
    DeleteItem *items=realloc(p->items,capacity*sizeof(*items));
    if(!items)return op_error(d,"Could not prepare deletion. Nothing was deleted.");
    p->items=items;p->capacity=capacity;
  }
  char *name=strdup(f->filename);
  if(!name)return op_error(d,"Could not prepare deletion. Nothing was deleted.");
  p->items[p->count++]=(DeleteItem){f->item_id,f->parent_id,folder,f->filesize,name};
  if(folder)p->folders++;else{p->files++;p->bytes+=f->filesize;}
  return 0;
}
static int build_delete_plan(LIBMTP_mtpdevice_t *d,uint32_t storage,uint32_t root,DeletePlan *p) {
  p->storage=storage;p->root=root;
  p->seen=calloc(DELETE_SET_SIZE,sizeof(*p->seen));
  if(!p->seen)return op_error(d,"Could not prepare deletion. Nothing was deleted.");
  LIBMTP_file_t *f=checked_object(d,storage,root);
  if(!f)return op_error(d,"The selected item is no longer available.");
  int rc=collect_delete(d,p,f,0);LIBMTP_destroy_file_t(f);return rc;
}
static int delete_item_compare(const void *a,const void *b) {
  const DeleteItem *x=a,*y=b;return x->id<y->id?-1:x->id>y->id;
}
static int same_delete_plan(DeletePlan *a,DeletePlan *b) {
  if(a->count!=b->count)return 0;
  DeleteItem *sorted=malloc(b->count*sizeof(*sorted));if(!sorted)return 0;
  memcpy(sorted,b->items,b->count*sizeof(*sorted));qsort(sorted,b->count,sizeof(*sorted),delete_item_compare);
  int equal=1;
  for(size_t i=0;i<a->count && equal;i++) {
    DeleteItem *x=&a->items[i],*y=bsearch(x,sorted,b->count,sizeof(*sorted),delete_item_compare);
    equal=y && x->parent==y->parent && x->folder==y->folder && x->size==y->size && !strcmp(x->name,y->name);
  }
  free(sorted);return equal;
}
static int deletion_command(LIBMTP_mtpdevice_t *d,int count,char **args,uint32_t sid,uint32_t id) {
  if(!strcmp(args[0],"deleteplan") && count==3) {
    free_delete_plan(&pending_delete);
    if(build_delete_plan(d,sid,id,&pending_delete)) {free_delete_plan(&pending_delete);return 1;}
    pending_delete.token=next_delete_token++;
    fprintf(out,"{\"type\":\"deletepreview\",\"storage\":%u,\"id\":%u,\"token\":\"%llu\",\"files\":%zu,\"folders\":%zu,\"bytes\":%llu,\"name\":",sid,id,(unsigned long long)pending_delete.token,pending_delete.files,pending_delete.folders,(unsigned long long)pending_delete.bytes);
    quoted(pending_delete.items[pending_delete.count-1].name);fprintf(out,"}\n");fflush(out);return 0;
  }
  uint64_t token=count==4?strtoull(args[3],NULL,10):0;
  if(count!=4 || !pending_delete.count || sid!=pending_delete.storage || id!=pending_delete.root || token!=pending_delete.token)
    return op_error(d,"Deletion confirmation expired. Select the item again.");
  if(!strcmp(args[0],"deletecancel")) {free_delete_plan(&pending_delete);return 0;}
  if(strcmp(args[0],"deletecommit")) return op_error(d,"Invalid deletion command.");
  DeletePlan current={0};
  int rc=build_delete_plan(d,sid,id,&current);
  if(!rc && !same_delete_plan(&pending_delete,&current)) rc=op_error(d,"Folder contents changed. Review deletion again. Nothing was deleted.");
  free_delete_plan(&current);
  if(!rc) {
    for(size_t i=0;i<pending_delete.count && !rc;i++) {
      if(cancelled){rc=1;break;}
      DeleteItem *item=&pending_delete.items[i];
      LIBMTP_file_t *f=checked_object(d,sid,item->id);
      if(!f || f->parent_id!=item->parent || (f->filetype==LIBMTP_FILETYPE_FOLDER)!=item->folder || !f->filename || strcmp(f->filename,item->name)) {
        if(f)LIBMTP_destroy_file_t(f);rc=op_error(d,"Deletion stopped because an item changed. Some items may already have been deleted.");break;
      }
      LIBMTP_destroy_file_t(f);
      if(item->folder) {
        LIBMTP_Clear_Errorstack(d);LIBMTP_file_t *children=LIBMTP_SwitchDrop_List(d,sid,item->id);
        int occupied=children!=NULL || LIBMTP_Get_Errorstack(d)!=NULL;destroy_files(children);
        if(occupied){rc=op_error(d,"Deletion stopped because a folder changed. Some items may already have been deleted.");break;}
      }
      if(LIBMTP_Delete_Object(d,item->id)) {rc=op_error(d,"Deletion failed. Some items may already have been deleted.");break;}
      fprintf(out,"{\"type\":\"deleteprogress\",\"done\":%zu,\"total\":%zu,\"name\":",i+1,pending_delete.count);quoted(item->name);fprintf(out,"}\n");fflush(out);
    }
  }
  free_delete_plan(&pending_delete);return rc;
}
