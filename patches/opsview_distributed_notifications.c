/*****************************************************************************
 *
 * OPSVIEW_DISTRIBUTED_NOTIFICATIONS.C - cancel a notification method if
 * configuration stops it. Useful for having notification methods which are
 * bound to a master or the active monitoring Nagios instance
 *
 * Example args:
 *   master=1,master-contactgroup=ov_monitored_by_master,{notificationmethodname1}=master,{notificationmethodname2}=ov_monitored_by_master
 *   master=0,master-contactgroup=ov_monitored_by_master,{notificationmethodname1}=master,{notificationmethodname2}=ov_monitored_by_master
 *
 * Rules:
 *   If method is not listed here, allow
 *   If method is listed and = master and master = 0, cancel
 *   If method = master and master = 1:
 *     If service and monitored by slave and state is unknown, cancel
 *     Otherwise allow
 *   If method = {name} and if host/service's contactgroups contains this name, allow
 *   Otherwise cancel
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
#include "../include/opsview_distributed_notifications.h"

/* include (minimum required) event broker header files */
#include "../include/nagios-4x/nebstructs.h"
#include "../include/nagios-4x/nebmodules.h"
#include "../include/nagios-4x/nebcallbacks.h"
#include "../include/nagios-4x/broker.h"
#include "../include/nagios-4x/neberrors.h"

/* include other Nagios header files for access to functions, data structs, etc. */
#include "../include/nagios-4x/common.h"
#include "../include/nagios-4x/nagios.h"
#include "../include/nagios-4x/downtime.h"
#include "../include/nagios-4x/comments.h"
#include "../include/nagios-4x/macros.h"

/* specify event broker API version (required) */
NEB_API_VERSION(CURRENT_NEB_API_VERSION)


#define MODULE_VERSION "0.5"
#define MODULE_NAME    "OPSVIEW_DISTRIBUTED_NOTIFICATIONS"

/*#define DEBUG 0*/

opsview_distributed_notifications_methods *opsview_distributed_notifications_methods_list=NULL;
void *opsview_distributed_notifications_module_handle=NULL;
char *opsview_distributed_notifications_monitored_by_master_contactgroup_name=NULL;


/**** NAGIOS VARIABLES ****/
extern int __nagios_object_structure_version;



/* this function gets called when the module is loaded by the event broker */
int nebmodule_init(int flags, char *args, void *handle){
	char temp_buffer[OPSVIEW_DISTRIBUTED_NOTIFICATIONS_MAX_BUFLEN];
    opsview_distributed_notifications_methods *this_notificationmethod;

	/* save our handle */
	opsview_distributed_notifications_module_handle=handle;

	/* log module info to the Nagios log file */
	snprintf(temp_buffer,sizeof(temp_buffer)-1,"opsview_distributed_notifications: %s %s Copyright (C) 2003-2013 Opsview Limited. All rights reserved",MODULE_NAME,MODULE_VERSION);
	temp_buffer[sizeof(temp_buffer)-1]='\x0';
	opsview_distributed_notifications_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);

	/* check Nagios object structure version */
	if(opsview_distributed_notifications_check_nagios_object_version()==NDO_ERROR)
		return -1;

	/* process arguments */
	if(opsview_distributed_notifications_process_module_args(args)==NDO_ERROR)
		return -1;

	/* do some initialization stuff... */
	if(opsview_distributed_notifications_init()==NDO_ERROR)
		return -1;

#ifdef DEBUG
    /* Log notificationmethods list */
    for(this_notificationmethod=opsview_distributed_notifications_methods_list;this_notificationmethod!=NULL;this_notificationmethod=this_notificationmethod->next){
        char *temp_contactgroupname;
        if(this_notificationmethod->contactgroupname != NULL) {
            if((temp_contactgroupname=strdup(this_notificationmethod->contactgroupname))==NULL){
                return NDO_ERROR;
            }
        } else {
            if((temp_contactgroupname=strdup("NULL"))==NULL){
                return NDO_ERROR;
            }
        }
        snprintf(temp_buffer,sizeof(temp_buffer)-1,"nmname=%s, action=%d, contactgroupname=%s\n", this_notificationmethod->name, this_notificationmethod->action, temp_contactgroupname);
        temp_buffer[sizeof(temp_buffer)-1]='\x0';
            opsview_distributed_notifications_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);
    }
#endif

	return 0;
        }


/* this function gets called when the module is unloaded by the event broker */
int nebmodule_deinit(int flags, int reason){
	char temp_buffer[OPSVIEW_DISTRIBUTED_NOTIFICATIONS_MAX_BUFLEN];

	/* do some shutdown stuff... */
	opsview_distributed_notifications_deinit();
	
	/* log a message to the Nagios log file */
	snprintf(temp_buffer,sizeof(temp_buffer)-1,"opsview_distributed_notifications: Shutdown complete.\n");
	temp_buffer[sizeof(temp_buffer)-1]='\x0';
        opsview_distributed_notifications_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);

	return 0;
        }



/****************************************************************************/
/* INIT/DEINIT FUNCTIONS                                                    */
/****************************************************************************/

/* checks to make sure Nagios object version matches what we know about */
int opsview_distributed_notifications_check_nagios_object_version(void){
	char temp_buffer[OPSVIEW_DISTRIBUTED_NOTIFICATIONS_MAX_BUFLEN];
	
	if(__nagios_object_structure_version!=CURRENT_OBJECT_STRUCTURE_VERSION){

		snprintf(temp_buffer,sizeof(temp_buffer)-1,"opsview_distributed_notifications: I've been compiled with support for revision %d of the internal Nagios object structures, but the Nagios daemon is currently using revision %d.  I'm going to unload so I don't cause any problems...\n",CURRENT_OBJECT_STRUCTURE_VERSION,__nagios_object_structure_version);
		temp_buffer[sizeof(temp_buffer)-1]='\x0';
		opsview_distributed_notifications_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);

		return NDO_ERROR;
	        }

	return NDO_OK;
        }


/* performs some initialization stuff */
int opsview_distributed_notifications_init(void){
	char temp_buffer[OPSVIEW_DISTRIBUTED_NOTIFICATIONS_MAX_BUFLEN];
	time_t current_time;

	/* register callbacks */
	if(opsview_distributed_notifications_register_callbacks()==NDO_ERROR)
		return NDO_ERROR;

	return NDO_OK;
        }


/* performs some shutdown stuff */
int opsview_distributed_notifications_deinit(void){
    opsview_distributed_notifications_methods *this_notificationmethod, *next_notificationmethod;

	/* deregister callbacks */
	opsview_distributed_notifications_deregister_callbacks();

    /* Free notification methods list */
    for(this_notificationmethod=opsview_distributed_notifications_methods_list;this_notificationmethod!=NULL;this_notificationmethod=next_notificationmethod){
        next_notificationmethod=this_notificationmethod->next;
        my_free(this_notificationmethod->name);
        my_free(this_notificationmethod->contactgroupname);
        my_free(this_notificationmethod);
    }
    my_free(opsview_distributed_notifications_monitored_by_master_contactgroup_name);
    opsview_distributed_notifications_methods_list=NULL;

	return NDO_OK;
        }



/****************************************************************************/
/* CONFIG FUNCTIONS                                                         */
/****************************************************************************/

/* process arguments that were passed to the module at startup */
int opsview_distributed_notifications_process_module_args(char *args){
	char *ptr=NULL;
	char **arglist=NULL;
	char **newarglist=NULL;
	int argcount=0;
	int memblocks=64;
	int arg=0;
    int is_master=0;

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
		if(opsview_distributed_notifications_process_config_var(arglist[arg],&is_master)==NDO_ERROR){
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
int opsview_distributed_notifications_process_config_var(char *arg, int *is_master){
	char *var=NULL;
	char *val=NULL;
    opsview_distributed_notifications_methods *new_notificationmethod=NULL;

	/* split var/val */
	var=strtok(arg,"=");
	val=strtok(NULL,"\n");

	/* skip incomplete var/val pairs */
	if(var==NULL || val==NULL)
		return NDO_OK;

	/* process the variable... */
	if(!strcmp(var,"master")) {
		*is_master=atoi(val);
    } else if (!strcmp(var,"master-contactgroup")) {
        opsview_distributed_notifications_monitored_by_master_contactgroup_name=strdup(val);
    }
    /* Otherwise assume is a notificationmethod name */
    else {
        if((new_notificationmethod=malloc(sizeof(opsview_distributed_notifications_methods)))==NULL)
            return NDO_ERROR;
        if((new_notificationmethod->name=(char *)strdup(var))==NULL){
            my_free(new_notificationmethod);
            return NDO_ERROR;
        }
        new_notificationmethod->contactgroupname=NULL;
        if(!strcmp(val,"master"))
            new_notificationmethod->action=*is_master;
        else {
            new_notificationmethod->action=2;
            if((new_notificationmethod->contactgroupname=(char *)strdup(val))==NULL){
                my_free(new_notificationmethod->name);
                my_free(new_notificationmethod);
                return NDO_ERROR;
            }
        }
        new_notificationmethod->next=opsview_distributed_notifications_methods_list;
        opsview_distributed_notifications_methods_list=new_notificationmethod;
    }

	return NDO_OK;
        }



/****************************************************************************/
/* UTILITY FUNCTIONS                                                        */
/****************************************************************************/

/* writes a string to Nagios logs */
int opsview_distributed_notifications_write_to_logs(char *buf, int flags){

	if(buf==NULL)
		return NDO_ERROR;

	return write_to_all_logs(buf,flags);
	}



/****************************************************************************/
/* CALLBACK FUNCTIONS                                                       */
/****************************************************************************/

/* registers for callbacks */
int opsview_distributed_notifications_register_callbacks(void){
	int priority=100;
	int result=NDO_OK;

	if(result==NDO_OK)
		result=neb_register_callback(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,opsview_distributed_notifications_module_handle,priority,opsview_distributed_notifications_broker_data);

	return result;
        }


/* deregisters callbacks */
int opsview_distributed_notifications_deregister_callbacks(void){

	neb_deregister_callback(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,opsview_distributed_notifications_broker_data);
	return NDO_OK;
        }


/* handles brokered event data */
int opsview_distributed_notifications_broker_data(int event_type, void *data){
	char *requested_notificationname=NULL;
    host *temp_host=NULL;
    service *temp_service=NULL;
    contactgroupsmember *temp_contactgroupsmember=NULL;
    opsview_distributed_notifications_methods *this_notificationmethod=NULL;
	nebstruct_contact_notification_method_data *ecdata=NULL;

	if(data==NULL)
		return 0;

	switch(event_type){

	case NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA:

		ecdata=(nebstruct_contact_notification_method_data *)data;

		if (ecdata->type != NEBTYPE_CONTACTNOTIFICATIONMETHOD_START) {
			return 0;
		}

		requested_notificationname=ecdata->command_name;
        if(requested_notificationname==NULL){
            return NEBERROR_CALLBACKBOUNDS;
        }

        for(this_notificationmethod=opsview_distributed_notifications_methods_list;this_notificationmethod!=NULL;this_notificationmethod=this_notificationmethod->next){
            if(!strcmp(this_notificationmethod->name,requested_notificationname)){
                if(this_notificationmethod->action==0){
                    return NEBERROR_CALLBACKOVERRIDE;
                } else if(this_notificationmethod->action==1) {
                    /* Need extra logic here. Although is master notified, need to strip off unknowns for things monitored by a slave */
                    if(ecdata->service_description!=NULL && ecdata->state==STATE_UNKNOWN && opsview_distributed_notifications_monitored_by_master_contactgroup_name) {
                        temp_service=(service *)ecdata->object_ptr;
                        for(temp_contactgroupsmember=temp_service->contact_groups;temp_contactgroupsmember!=NULL;temp_contactgroupsmember=temp_contactgroupsmember->next) {
                            if(!strcmp(temp_contactgroupsmember->group_name,opsview_distributed_notifications_monitored_by_master_contactgroup_name)){
                                return 0;
                            }
                        }
                        return NEBERROR_CALLBACKOVERRIDE;
                    }
                    return 0;
                }

                if(ecdata->service_description==NULL) {
                    temp_host=(host *)ecdata->object_ptr;
                    for(temp_contactgroupsmember=temp_host->contact_groups;temp_contactgroupsmember!=NULL;temp_contactgroupsmember=temp_contactgroupsmember->next) {
                        if(!strcmp(temp_contactgroupsmember->group_name,this_notificationmethod->contactgroupname)){
                            return 0;
                        }
                    }
                    return NEBERROR_CALLBACKOVERRIDE;
                } else {
                    temp_service=(service *)ecdata->object_ptr;
                    for(temp_contactgroupsmember=temp_service->contact_groups;temp_contactgroupsmember!=NULL;temp_contactgroupsmember=temp_contactgroupsmember->next) {
                        if(!strcmp(temp_contactgroupsmember->group_name,this_notificationmethod->contactgroupname)){
                            return 0;
                        }
                    }
                    return NEBERROR_CALLBACKOVERRIDE;
                }
            }
        }
		break;

	default:
		return 0;
		break;
	        }

	return 0;
        }



