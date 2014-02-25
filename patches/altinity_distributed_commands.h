/************************************************************************
 *
 * ALTINITY_DISTRIBUTED_COMMANDS.H - NEB Module Include File for 
 * Altinity's distributed commands module
 *
 * Copyright (C) 2003-2008 Opsview Limited. All rights reserved, after Ethan Galstad
 *
 ************************************************************************/

#ifndef _NDBXT_NDOMOD_H
#define _NDBXT_NDOMOD_H


/* this is needed for access to daemon's internal data */
#define NSCORE 1

#define ALTINITY_DISTRIBUTED_COMMANDS_MAX_BUFLEN 4096

int nebmodule_init(int,char *,void *);
int nebmodule_deinit(int,int);

int altinity_distributed_commands_init(void);
int altinity_distributed_commands_deinit(void);

int altinity_distributed_commands_check_nagios_object_version(void);

int altinity_distributed_commands_write_to_logs(char *,int);

int altinity_distributed_commands_process_module_args(char *);
int altinity_distributed_commands_process_config_var(char *);

int altinity_distributed_commands_register_callbacks(void);
int altinity_distributed_commands_deregister_callbacks(void);

int altinity_distributed_commands_broker_data(int,void *);

#endif
