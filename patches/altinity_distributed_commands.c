/*****************************************************************************
 *
 * ALTINITY_DISTRIBUTED_COMMANDS.C - Run an external command when certain
 * Nagios external commands are submitted
 *
 * Initially based on 
 * NDOMOD.C - Nagios Data Output Event Broker Module
 *
 * Copyright (C) 2003-2008 Opsview Limited. All rights reserved, after Ethan Galstad
 *
 *****************************************************************************/

/* include our project's header files */
#include "../include/common.h"
#include "../include/io.h"
#include "../include/utils.h"
#include "../include/protoapi.h"
#include "../include/altinity_distributed_commands.h"

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
#define MODULE_NAME    "ALTINITY_DISTRIBUTED_COMMANDS"


void *altinity_distributed_commands_module_handle=NULL;
char *altinity_distributed_commands_cache_file=NULL;

int altinity_distributed_commands_command_timeout=60;

extern int errno;

/**** NAGIOS VARIABLES ****/
extern int __nagios_object_structure_version;



/* this function gets called when the module is loaded by the event broker */
int nebmodule_init(int flags, char *args, void *handle){
	char temp_buffer[ALTINITY_DISTRIBUTED_COMMANDS_MAX_BUFLEN];

	/* save our handle */
	altinity_distributed_commands_module_handle=handle;

	/* log module info to the Nagios log file */
	snprintf(temp_buffer,sizeof(temp_buffer)-1,"altinity_distributed_commands: %s %s Copyright (C) 2003-2008 Opsview Limited. All rights reserved",MODULE_NAME,MODULE_VERSION);
	temp_buffer[sizeof(temp_buffer)-1]='\x0';
	altinity_distributed_commands_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);

	/* check Nagios object structure version */
	if(altinity_distributed_commands_check_nagios_object_version()==NDO_ERROR)
		return -1;

	/* process arguments */
	if(altinity_distributed_commands_process_module_args(args)==NDO_ERROR)
		return -1;

	/* do some initialization stuff... */
	if(altinity_distributed_commands_init()==NDO_ERROR)
		return -1;

	return 0;
        }


/* this function gets called when the module is unloaded by the event broker */
int nebmodule_deinit(int flags, int reason){
	char temp_buffer[ALTINITY_DISTRIBUTED_COMMANDS_MAX_BUFLEN];

	/* do some shutdown stuff... */
	altinity_distributed_commands_deinit();
	
	/* log a message to the Nagios log file */
	snprintf(temp_buffer,sizeof(temp_buffer)-1,"altinity_distributed_commands: Shutdown complete.\n");
	temp_buffer[sizeof(temp_buffer)-1]='\x0';
        altinity_distributed_commands_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);

	return 0;
        }



/****************************************************************************/
/* INIT/DEINIT FUNCTIONS                                                    */
/****************************************************************************/

/* checks to make sure Nagios object version matches what we know about */
int altinity_distributed_commands_check_nagios_object_version(void){
	char temp_buffer[ALTINITY_DISTRIBUTED_COMMANDS_MAX_BUFLEN];
	
	if(__nagios_object_structure_version!=CURRENT_OBJECT_STRUCTURE_VERSION){

		snprintf(temp_buffer,sizeof(temp_buffer)-1,"altinity_distributed_commands: I've been compiled with support for revision %d of the internal Nagios object structures, but the Nagios daemon is currently using revision %d.  I'm going to unload so I don't cause any problems...\n",CURRENT_OBJECT_STRUCTURE_VERSION,__nagios_object_structure_version);
		temp_buffer[sizeof(temp_buffer)-1]='\x0';
		altinity_distributed_commands_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);

		return NDO_ERROR;
	        }

	return NDO_OK;
        }


/* performs some initialization stuff */
int altinity_distributed_commands_init(void){
	char temp_buffer[ALTINITY_DISTRIBUTED_COMMANDS_MAX_BUFLEN];
	time_t current_time;

	/* register callbacks */
	if(altinity_distributed_commands_register_callbacks()==NDO_ERROR)
		return NDO_ERROR;

	return NDO_OK;
        }


/* performs some shutdown stuff */
int altinity_distributed_commands_deinit(void){

	/* deregister callbacks */
	altinity_distributed_commands_deregister_callbacks();

	return NDO_OK;
        }



/****************************************************************************/
/* CONFIG FUNCTIONS                                                         */
/****************************************************************************/

/* process arguments that were passed to the module at startup */
int altinity_distributed_commands_process_module_args(char *args){
	char *ptr=NULL;
	char **arglist=NULL;
	char **newarglist=NULL;
	int argcount=0;
	int memblocks=64;
	int arg=0;

	if(args==NULL)
		return NDO_OK;


	/* get all the var/val argument pairs */

	/* allocate some memory */
        if((arglist=(char **)malloc(memblocks*sizeof(char **)))==NULL)
                return NDO_ERROR;

	/* process all args */
        ptr=strtok(args,",");
        while(ptr){

		/* save the argument */
                arglist[argcount++]=strdup(ptr);

		/* allocate more memory if needed */
                if(!(argcount%memblocks)){
                        if((newarglist=(char **)realloc(arglist,(argcount+memblocks)*sizeof(char **)))==NULL){
				for(arg=0;arg<argcount;arg++)
					free(arglist[argcount]);
				free(arglist);
				return NDO_ERROR;
			        }
			else
				arglist=newarglist;
                        }

                ptr=strtok(NULL,",");
                }

	/* terminate the arg list */
        arglist[argcount]='\x0';


	/* process each argument */
	for(arg=0;arg<argcount;arg++){
		if(altinity_distributed_commands_process_config_var(arglist[arg])==NDO_ERROR){
			for(arg=0;arg<argcount;arg++)
				free(arglist[arg]);
			free(arglist);
			return NDO_ERROR;
		        }
	        }

	/* free allocated memory */
	for(arg=0;arg<argcount;arg++)
		free(arglist[arg]);
	free(arglist);
	
	return NDO_OK;
        }



/* process a single module config variable */
int altinity_distributed_commands_process_config_var(char *arg){
	char *var=NULL;
	char *val=NULL;

	/* split var/val */
	var=strtok(arg,"=");
	val=strtok(NULL,"\n");

	/* skip incomplete var/val pairs */
	if(var==NULL || val==NULL)
		return NDO_OK;

	/* process the variable... */

	if(!strcmp(var,"cache_file"))
		altinity_distributed_commands_cache_file=strdup(val);

	else
		return NDO_ERROR;

	return NDO_OK;
        }



/****************************************************************************/
/* UTILITY FUNCTIONS                                                        */
/****************************************************************************/

/* writes a string to Nagios logs */
int altinity_distributed_commands_write_to_logs(char *buf, int flags){

	if(buf==NULL)
		return NDO_ERROR;

	return write_to_all_logs(buf,flags);
	}



/****************************************************************************/
/* CALLBACK FUNCTIONS                                                       */
/****************************************************************************/

/* registers for callbacks */
int altinity_distributed_commands_register_callbacks(void){
	int priority=0;
	int result=NDO_OK;

	if(result==NDO_OK)
		result=neb_register_callback(NEBCALLBACK_EXTERNAL_COMMAND_DATA,altinity_distributed_commands_module_handle,priority,altinity_distributed_commands_broker_data);

	return result;
        }


/* deregisters callbacks */
int altinity_distributed_commands_deregister_callbacks(void){

	neb_deregister_callback(NEBCALLBACK_EXTERNAL_COMMAND_DATA,altinity_distributed_commands_broker_data);
	return NDO_OK;
        }


/* handles brokered event data */
int altinity_distributed_commands_broker_data(int event_type, void *data){
	char *es[8];
	int x=0;
	nebstruct_external_command_data *ecdata=NULL;

	if(data==NULL)
		return 0;

	/* initialize escaped buffers */
	for(x=0;x<8;x++)
		es[x]=NULL;

	switch(event_type){

	case NEBCALLBACK_EXTERNAL_COMMAND_DATA:

		ecdata=(nebstruct_external_command_data *)data;

		if (ecdata->type == NEBTYPE_EXTERNALCOMMAND_START) {
			/* printf("Ignoring start\n"); */
			return 0;
		}

		es[0]=ndo_escape_buffer(ecdata->command_string);
		es[1]=ndo_escape_buffer(ecdata->command_args);

		/* all the schedule downtimes (SCHEDULE_HOST_DOWNTIME, SCHEDULE_SVC_DOWNTIME) have a trigger id, which maybe a problem on slave */
		if (! (
			strcmp(es[0], "SCHEDULE_AND_PROPAGATE_HOST_DOWNTIME")==0 ||
			strcmp(es[0], "SCHEDULE_AND_PROPAGATE_TRIGGERED_HOST_DOWNTIME")==0 ||
			strcmp(es[0], "SCHEDULE_FORCED_HOST_CHECK")==0 ||
			strcmp(es[0], "SCHEDULE_FORCED_HOST_SVC_CHECKS")==0 ||
			strcmp(es[0], "SCHEDULE_FORCED_SVC_CHECK")==0 ||
			strcmp(es[0], "SCHEDULE_HOSTGROUP_HOST_DOWNTIME")==0 ||
			strcmp(es[0], "SCHEDULE_HOSTGROUP_SVC_DOWNTIME")==0 ||
			strcmp(es[0], "SCHEDULE_HOST_CHECK")==0 ||
			strcmp(es[0], "SCHEDULE_HOST_SVC_CHECKS")==0 ||
			strcmp(es[0], "SCHEDULE_SVC_CHECK")==0 ||
			strcmp(es[0], "SCHEDULE_SERVICEGROUP_HOST_DOWNTIME")==0 ||
			strcmp(es[0], "SCHEDULE_SERVICEGROUP_SVC_DOWNTIME")==0 ||
			strcmp(es[0], "DISABLE_ALL_NOTIFICATIONS_BEYOND_HOST")==0 ||
			strcmp(es[0], "DISABLE_HOSTGROUP_HOST_NOTIFICATIONS")==0 ||
			strcmp(es[0], "DISABLE_HOSTGROUP_SVC_NOTIFICATIONS")==0 ||
			strcmp(es[0], "DISABLE_HOST_AND_CHILD_NOTIFICATIONS")==0 ||
			strcmp(es[0], "DISABLE_HOST_FLAP_DETECTION")==0 ||
			strcmp(es[0], "DISABLE_HOST_NOTIFICATIONS")==0 ||
			strcmp(es[0], "DISABLE_HOST_SVC_NOTIFICATIONS")==0 ||
			strcmp(es[0], "DISABLE_SERVICEGROUP_HOST_NOTIFICATIONS")==0 ||
			strcmp(es[0], "DISABLE_SERVICEGROUP_SVC_NOTIFICATIONS")==0 ||
			strcmp(es[0], "DISABLE_SERVICE_FLAP_DETECTION")==0 ||
			strcmp(es[0], "DISABLE_SVC_NOTIFICATIONS")==0 ||
			strcmp(es[0], "ENABLE_ALL_NOTIFICATIONS_BEYOND_HOST")==0 ||
			strcmp(es[0], "ENABLE_HOSTGROUP_HOST_NOTIFICATIONS")==0 ||
			strcmp(es[0], "ENABLE_HOSTGROUP_SVC_NOTIFICATIONS")==0 ||
			strcmp(es[0], "ENABLE_HOST_AND_CHILD_NOTIFICATIONS")==0 ||
			strcmp(es[0], "ENABLE_HOST_FLAP_DETECTION")==0 ||
			strcmp(es[0], "ENABLE_HOST_NOTIFICATIONS")==0 ||
			strcmp(es[0], "ENABLE_HOST_SVC_NOTIFICATIONS")==0 ||
			strcmp(es[0], "ENABLE_SERVICEGROUP_HOST_NOTIFICATIONS")==0 ||
			strcmp(es[0], "ENABLE_SERVICEGROUP_SVC_NOTIFICATIONS")==0 ||
			strcmp(es[0], "ENABLE_SERVICE_FLAP_DETECTION")==0 ||
			strcmp(es[0], "ENABLE_SVC_NOTIFICATIONS")==0 ||
			strcmp(es[0], "ACKNOWLEDGE_HOST_PROBLEM")==0 ||
			strcmp(es[0], "ACKNOWLEDGE_SVC_PROBLEM")==0 ||
			strcmp(es[0], "REMOVE_SVC_ACKNOWLEDGEMENT")==0 ||
			strcmp(es[0], "REMOVE_HOST_ACKNOWLEDGEMENT")==0 ||
			strcmp(es[0], "ADD_HOST_COMMENT")==0 ||
			strcmp(es[0], "ADD_SVC_COMMENT")==0 ||
			strcmp(es[0], "DEL_ALL_HOST_COMMENTS")==0 ||
			strcmp(es[0], "DEL_ALL_SVC_COMMENTS")==0 ||
			strcmp(es[0], "DEL_HOSTGROUP_HOST_DOWNTIME")==0 ||
			strcmp(es[0], "DEL_HOSTGROUP_SVC_DOWNTIME")==0 ||
			strcmp(es[0], "DEL_DOWNTIME_BY_HOST_NAME")==0 ||
			strcmp(es[0], "DEL_DOWNTIME_BY_HOSTGROUP_NAME")==0 ||
			strcmp(es[0], "DEL_DOWNTIME_BY_START_TIME_COMMENT")==0 ||
			strcmp(es[0], "DISABLE_NOTIFICATIONS")==0 ||
			strcmp(es[0], "ENABLE_NOTIFICATIONS")==0 ||
			strcmp(es[0], "START_EXECUTING_HOST_CHECKS")==0 ||
			strcmp(es[0], "STOP_EXECUTING_HOST_CHECKS")==0 ||
			strcmp(es[0], "START_EXECUTING_SVC_CHECKS")==0 ||
			strcmp(es[0], "STOP_EXECUTING_SVC_CHECKS")==0 ||
			strcmp(es[0], "START_ACCEPTING_PASSIVE_HOST_CHECKS")==0 ||
			strcmp(es[0], "STOP_ACCEPTING_PASSIVE_HOST_CHECKS")==0 ||
			strcmp(es[0], "START_ACCEPTING_PASSIVE_SVC_CHECKS")==0 ||
			strcmp(es[0], "STOP_ACCEPTING_PASSIVE_SVC_CHECKS")==0
        ) ) {
			/* printf("Ignoring %s\n",  es[0]); */
			break;
		}
			
/* removed - printf's not required
		printf("\n%d:\n%d=%d\n%d=%d\n%d=%d\n%d=%ld.%ld\n%d=%d\n%d=%lu\n%d=%s\n%d=%s\n%d\n\n"
			 ,NDO_API_EXTERNALCOMMANDDATA
			 ,NDO_DATA_TYPE
			 ,ecdata->type
			 ,NDO_DATA_FLAGS
			 ,ecdata->flags
			 ,NDO_DATA_ATTRIBUTES
			 ,ecdata->attr
			 ,NDO_DATA_TIMESTAMP
			 ,ecdata->timestamp.tv_sec
			 ,ecdata->timestamp.tv_usec
			 ,NDO_DATA_COMMANDTYPE
			 ,ecdata->command_type
			 ,NDO_DATA_ENTRYTIME
			 ,(unsigned long)ecdata->entry_time
			 ,NDO_DATA_COMMANDSTRING
			 ,(es[0]==NULL)?"":es[0]
			 ,NDO_DATA_COMMANDARGS
			 ,(es[1]==NULL)?"":es[1]
			 ,NDO_API_ENDDATA
			);
	
		printf("Running command here\n");
*/
		setenv("ALTINITY_COMMANDSTRING", (es[0]==NULL)?"":es[0], 1);
		setenv("ALTINITY_COMMANDARGS",   (es[1]==NULL)?"":es[1], 1);
		if (altinity_distributed_commands_send((es[0]==NULL)?"":es[0],(es[1]==NULL)?"":es[1]) != NDO_OK) {
			printf("altinity_distributed_commands: error with %s (check nagios.log)\n",altinity_distributed_commands_cache_file);
		}
		unsetenv("ALTINITY_COMMANDSTRING");
		unsetenv("ALTINITY_COMMANDARGS");

		break;

	default:
		return 0;
		break;
	        }

	/* free escaped buffers */
	for(x=0;x<8;x++){
		free(es[x]);
		es[x]=NULL;
	        }

	return 0;
        }



/* used to execute distributed command */
int altinity_distributed_commands_send(char *cmd_string, char *cmd_args) {
	FILE *fp = NULL;
	char temp_buffer[ALTINITY_DISTRIBUTED_COMMANDS_MAX_BUFLEN];
	char command[ALTINITY_DISTRIBUTED_COMMANDS_MAX_BUFLEN];

	snprintf(command, ALTINITY_DISTRIBUTED_COMMANDS_MAX_BUFLEN, "%s;%s\n", cmd_string, cmd_args);

	fp = fopen(altinity_distributed_commands_cache_file, "a");

	if(fp == NULL ) {
		snprintf(temp_buffer,sizeof(temp_buffer)-1,"altinity_distributed_commands: unable to write to %s: error number %d (%s)", altinity_distributed_commands_cache_file, errno, strerror(errno));
		temp_buffer[sizeof(temp_buffer)-1]='\x0';
		altinity_distributed_commands_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);
		return NDO_ERROR;
	}

	if(fputs(command,fp) < 1) {
		snprintf(temp_buffer,sizeof(temp_buffer)-1,"altinity_distributed_commands: unable to write to %s: error number %d (%s)", altinity_distributed_commands_cache_file, errno, strerror(errno));
		temp_buffer[sizeof(temp_buffer)-1]='\x0';
		altinity_distributed_commands_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);
		return NDO_ERROR;
	}

	fclose(fp);

	return NDO_OK;
        }
