/*****************************************************************************
 *
 * ALTINITY_SET_INITIAL_STATE.C - Sets all objects that have no initial state to 
 * be OK, via a passive command
 *
 * Initially based on 
 * NDOMOD.C - Nagios Data Output Event Broker Module
 *
 * Copyright (C) 2003-2013 Opsview Limited. All rights reserved, after Ethan Galstad
 *
 *****************************************************************************/

/* include our project's header files */
#include "../include/common.h"
#include "../include/io.h"
#include "../include/utils.h"
#include "../include/protoapi.h"
#include "../include/altinity_set_initial_state.h"

/* include (minimum required) event broker header files */
#include "../include/nagios-4x/nebstructs.h"
#include "../include/nagios-4x/nebmodules.h"
#include "../include/nagios-4x/nebcallbacks.h"
#include "../include/nagios-4x/broker.h"

/* include other Nagios header files for access to functions, data structs, etc. */
#include "../include/nagios-4x/common.h"
#include "../include/nagios-4x/nagios.h"
#include "../include/nagios-4x/downtime.h"
#include "../include/nagios-4x/comments.h"
#include "../include/nagios-4x/macros.h"

/* specify event broker API version (required) */
NEB_API_VERSION(CURRENT_NEB_API_VERSION)


#define MODULE_VERSION "0.5"
#define MODULE_NAME    "ALTINITY_SET_INITIAL_STATE"


extern host *host_list;
extern service *service_list;

/**** NAGIOS VARIABLES ****/
extern int __nagios_object_structure_version;

void *altinity_set_initial_state_module_handle=NULL;


/* this function gets called when the module is loaded by the event broker */
int nebmodule_init(int flags, char *args, void *handle){
	char temp_buffer[ALTINITY_SET_INITIAL_STATE_MAX_BUFLEN];

	/* save our handle */
	altinity_set_initial_state_module_handle=handle;

	/* log module info to the Nagios log file */
	snprintf(temp_buffer,sizeof(temp_buffer)-1,"altinity_set_initial_state: %s %s Copyright (C) 2003-2013 Opsview Limited. All rights reserved",MODULE_NAME,MODULE_VERSION);
	temp_buffer[sizeof(temp_buffer)-1]='\x0';
	altinity_set_initial_state_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);

	/* check Nagios object structure version */
	if(altinity_set_initial_state_check_nagios_object_version()==NDO_ERROR)
		return -1;

	/* do some initialization stuff... */
	if(altinity_set_initial_state_init()==NDO_ERROR)
		return -1;

	return 0;
        }


/* this function gets called when the module is unloaded by the event broker */
int nebmodule_deinit(int flags, int reason){
	char temp_buffer[ALTINITY_SET_INITIAL_STATE_MAX_BUFLEN];

	/* do some shutdown stuff... */
	altinity_set_initial_state_deinit();
	
	/* log a message to the Nagios log file */
	snprintf(temp_buffer,sizeof(temp_buffer)-1,"altinity_set_initial_state: Shutdown complete.\n");
	temp_buffer[sizeof(temp_buffer)-1]='\x0';
        altinity_set_initial_state_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);

	return 0;
        }



/****************************************************************************/
/* INIT/DEINIT FUNCTIONS                                                    */
/****************************************************************************/

/* checks to make sure Nagios object version matches what we know about */
int altinity_set_initial_state_check_nagios_object_version(void){
	char temp_buffer[ALTINITY_SET_INITIAL_STATE_MAX_BUFLEN];
	
	if(__nagios_object_structure_version!=CURRENT_OBJECT_STRUCTURE_VERSION){

		snprintf(temp_buffer,sizeof(temp_buffer)-1,"altinity_set_initial_state: I've been compiled with support for revision %d of the internal Nagios object structures, but the Nagios daemon is currently using revision %d.  I'm going to unload so I don't cause any problems...\n",CURRENT_OBJECT_STRUCTURE_VERSION,__nagios_object_structure_version);
		temp_buffer[sizeof(temp_buffer)-1]='\x0';
		altinity_set_initial_state_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);

		return NDO_ERROR;
	        }

	return NDO_OK;
        }


/* performs some initialization stuff */
int altinity_set_initial_state_init(void){
	time_t current_time;

	/* register callbacks */
	if(altinity_set_initial_state_register_callbacks()==NDO_ERROR)
		return NDO_ERROR;

	return NDO_OK;
        }


/* performs some shutdown stuff */
int altinity_set_initial_state_deinit(void){

	/* deregister callbacks */
	altinity_set_initial_state_deregister_callbacks();

	return NDO_OK;
        }




/****************************************************************************/
/* UTILITY FUNCTIONS                                                        */
/****************************************************************************/

/* writes a string to Nagios logs */
int altinity_set_initial_state_write_to_logs(char *buf, int flags){

	if(buf==NULL)
		return NDO_ERROR;

	return write_to_all_logs(buf,flags);
	}



/****************************************************************************/
/* CALLBACK FUNCTIONS                                                       */
/****************************************************************************/

/* registers for callbacks */
int altinity_set_initial_state_register_callbacks(void){
	int priority=0;
	int result=NDO_OK;

	if(result==NDO_OK)
		result=neb_register_callback(NEBCALLBACK_PROCESS_DATA,altinity_set_initial_state_module_handle,priority,altinity_set_initial_state_broker_data);

	return result;
        }


/* deregisters callbacks */
int altinity_set_initial_state_deregister_callbacks(void){

	neb_deregister_callback(NEBCALLBACK_PROCESS_DATA,altinity_set_initial_state_broker_data);
	return NDO_OK;
        }


/* handles brokered event data */
int altinity_set_initial_state_broker_data(int event_type, void *data){
	nebstruct_external_command_data *ecdata=NULL;

	if(data==NULL)
		return 0;

	switch(event_type){

	case NEBCALLBACK_PROCESS_DATA:

		ecdata=(nebstruct_external_command_data *)data;

		if (ecdata->type != NEBTYPE_PROCESS_EVENTLOOPSTART) {
			return 0;
		}

		/* Loop through all hosts and find the ones with has_been_checked == FALSE */
		altinity_set_initial_state_to_ok();
			
		break;

	default:
		return 0;
		break;
	        }

	return 0;
        }



int altinity_set_initial_state_to_ok(void) {
	host *temp_host;
	service *temp_service;
	time_t now;
	char *output = NULL;

	now=time(NULL);
	
	for(temp_host=host_list;temp_host!=NULL;temp_host=temp_host->next){
		if(temp_host->has_been_checked==FALSE){
			// This must be copied because Nagios 4 will change data inline
			output = strdup("Host assumed UP - no results received");
			process_passive_host_check(now,temp_host->name,0,output);
			free(output);
			}
		}

	for(temp_service=service_list;temp_service!=NULL;temp_service=temp_service->next){
		if(temp_service->has_been_checked==FALSE){
			output = strdup("Service assumed OK - no results received");
			process_passive_service_check(now,temp_service->host_name,temp_service->description,0,output);
			free(output);
			}
		}

	}

