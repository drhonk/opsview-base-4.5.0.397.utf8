/************************************************************************
 *
 * ALTINITY_SET_INITIAL_STATE.H - NEB Module Include File for 
 * Altinity's set initial state module
 *
 * Copyright (C) 2003-2013 Opsview Limited. All rights reserved, after Ethan Galstad
 *
 ************************************************************************/

#ifndef _NDBXT_NDOMOD_H
#define _NDBXT_NDOMOD_H


/* this is needed for access to daemon's internal data */
#define NSCORE 1

#define ALTINITY_SET_INITIAL_STATE_MAX_BUFLEN 4096

int nebmodule_init(int,char *,void *);
int nebmodule_deinit(int,int);

int altinity_set_initial_state_init(void);
int altinity_set_initial_state_deinit(void);

int altinity_set_initial_state_check_nagios_object_version(void);

int altinity_set_initial_state_write_to_logs(char *,int);

int altinity_set_initial_state_register_callbacks(void);
int altinity_set_initial_state_deregister_callbacks(void);

int altinity_set_initial_state_broker_data(int,void *);

#endif
