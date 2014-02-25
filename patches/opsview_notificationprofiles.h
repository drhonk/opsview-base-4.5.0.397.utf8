/************************************************************************
 *
 * OPSVIEW_NOTIFICATIONPROFILES.H - NEB Module Include File for 
 * Opsview's notification profiles functionality
 *
 * Copyright (C) 2003-2013 Opsview Limited. All rights reserved, after Ethan Galstad
 *
 ************************************************************************/

#ifndef _NDBXT_NDOMOD_H
#define _NDBXT_NDOMOD_H


/* this is needed for access to daemon's internal data */
#define NSCORE 1

#define OPSVIEW_NOTIFICATIONPROFILES_MAX_BUFLEN 4096

/* Notification methods */
typedef struct opsview_notificationprofiles_method_struct {
    char *name;
    struct opsview_notificationprofiles_method_struct *next;
}opsview_notificationprofiles_method;

/* User */
typedef struct opsview_notificationprofiles_user_struct {
    char *name;
    opsview_notificationprofiles_method *methods;
    struct opsview_notificationprofiles_user_struct *next;
}opsview_notificationprofiles_user;

int nebmodule_init(int,char *,void *);
int nebmodule_deinit(int,int);

int opsview_notificationprofiles_init(void);
int opsview_notificationprofiles_deinit(void);

int opsview_notificationprofiles_check_nagios_object_version(void);

int opsview_notificationprofiles_write_to_logs(char *,int);

int opsview_notificationprofiles_process_module_args(char *);
int opsview_notificationprofiles_process_config_var(char *, int *);

int opsview_notificationprofiles_register_callbacks(void);
int opsview_notificationprofiles_deregister_callbacks(void);

int opsview_notificationprofiles_broker_data(int,void *);

#endif
