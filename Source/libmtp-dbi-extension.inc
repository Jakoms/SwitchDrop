/* SwitchDrop adapter for libmtp 1.1.23, MIT licensed.
 * Appended during the reproducible build; upstream sources remain in ThirdParty.
 * DBI may expose root entries via GetObjectPropList while GetObjectHandles is empty.
 */
LIBMTP_file_t *LIBMTP_SwitchDrop_List(LIBMTP_mtpdevice_t *device, uint32_t storage, uint32_t parent) {
  PTPParams *params=(PTPParams*)device->params;
  MTPProperties *props=NULL;
  int count=0;
  uint32_t query=parent==0xffffffff?storage:parent;
  uint16_t rc=ptp_mtp_getobjectproplist_generic(params,query,0,0xffffffff,0,1,&props,&count);
  if(rc!=PTP_RC_OK) {
    if(props) ptp_destroy_object_prop_list(props,count);
    return LIBMTP_Get_Files_And_Folders(device,storage,parent);
  }
  LIBMTP_file_t *all=NULL;
  for(int i=0;i<count;i++) {
    MTPProperties *p=&props[i];
    LIBMTP_file_t *f=all;
    while(f && f->item_id!=p->ObjectHandle) f=f->next;
    if(!f) {
      f=LIBMTP_new_file_t(); f->item_id=p->ObjectHandle;
      f->parent_id=parent; f->next=all; all=f;
    }
    switch(p->property) {
      case PTP_OPC_StorageID: f->storage_id=p->propval.u32; break;
      case PTP_OPC_ParentObject: f->parent_id=p->propval.u32; break;
      case PTP_OPC_ObjectFormat: f->filetype=p->propval.u16==PTP_OFC_Association?LIBMTP_FILETYPE_FOLDER:LIBMTP_FILETYPE_UNKNOWN; break;
      case PTP_OPC_ObjectFileName:
        free(f->filename); f->filename=p->propval.str?strdup(p->propval.str):NULL; break;
      case PTP_OPC_ObjectSize:
        f->filesize=p->datatype==PTP_DTC_UINT64?p->propval.u64:p->propval.u32; break;
      default: break;
    }
  }
  ptp_destroy_object_prop_list(props,count);
  LIBMTP_file_t *result=NULL;
  while(all) {
    LIBMTP_file_t *next=all->next; all->next=NULL;
    int rootparent=parent==0xffffffff && (all->parent_id==0 || all->parent_id==storage || all->parent_id==0xffffffff);
    if(all->item_id!=query && all->storage_id==storage && all->filename && (all->parent_id==parent || rootparent)) {
      all->next=result; result=all;
    } else LIBMTP_destroy_file_t(all);
    all=next;
  }
  return result;
}
