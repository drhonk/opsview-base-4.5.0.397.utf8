/************************************************************************
 *
 * OPSVIEW_DISTRIBUTED_NOTIFICATIONS.H - NEB Module Include File for 
 * Opsview's distributed notifications supressor
 *
 * Copyright (C) 2003-2013 Opsview Limited. All rights reserved, after Ethan Galstad
 *
 ************************************************************************/

#ifndef _NDBXT_NDOMOD_H
#define _NDBXT_NDOMOD_H


/* this is needed for access to daemon's internal data */
#define NSCORE 1

#define OPSVIEW_DISTRIBUTED_NOTIFICATIONS_MAX_BUFLEN 4096

/* Notification methods */
typedef struct opsview_distributed_notifications_methods_struct {
    char *name;
    int  action;     /* 0 = ignore, 1 = always, 2 = lookup contactgroupname */
    char *contactgroupname;
    struct opsview_distributed_notifications_methods_struct *next;
}opsview_distributed_notifications_methods;

int nebmodule_init(int,char *,void *);
int nebmodule_deinit(int,int);

int opsview_distributed_notifications_init(void);
int opsview_distributed_notifications_deinit(void);

int opsview_distributed_notifications_check_nagios_object_version(void);

int opsview_distributed_notifications_write_to_logs(char *,int);

int opsview_distributed_notifications_process_module_args(char *);
int opsview_distributed_notifications_process_config_var(char *, int *);

int opsview_distributed_notifications_register_callbacks(void);
int opsview_distributed_notifications_deregister_callbacks(void);

int opsview_distributed_notifications_broker_data(int,void *);

#endif
