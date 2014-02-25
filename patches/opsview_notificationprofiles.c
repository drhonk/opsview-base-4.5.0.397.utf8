/*****************************************************************************
 *
 * OPSVIEW_NOTIFICATIONPROFILES.C - flatten a contact name into a user name
 * and only allow 1 notification method to be sent per user
 * This allows flexible notifications to be configured
 *
 * Rules:
 *   Given a contact name, derive the user name (strip everything after a '/')
 *   For this user name, see if the requested notification method has already been sent
 *   If yes, cancel
 *   If no, allow
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
#include "../include/opsview_notificationprofiles.h"

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
#define MODULE_NAME    "OPSVIEW_NOTIFICATIONPROFILES"

#define DEBUG 0

opsview_notificationprofiles_user *opsview_notificationprofiles_users_list=NULL;
void *opsview_notificationprofiles_module_handle=NULL;
extern notification    *notification_list;

extern int errno;

/**** NAGIOS VARIABLES ****/
extern int __nagios_object_structure_version;



/* this function gets called when the module is loaded by the event broker */
int nebmodule_init(int flags, char *args, void *handle){
	char temp_buffer[OPSVIEW_NOTIFICATIONPROFILES_MAX_BUFLEN];

	/* save our handle */
	opsview_notificationprofiles_module_handle=handle;

	/* log module info to the Nagios log file */
	snprintf(temp_buffer,sizeof(temp_buffer)-1,"opsview_notificationprofiles: %s %s Copyright (C) 2003-2013 Opsview Limited. All rights reserved",MODULE_NAME,MODULE_VERSION);
	temp_buffer[sizeof(temp_buffer)-1]='\x0';
	opsview_notificationprofiles_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);

	/* check Nagios object structure version */
	if(opsview_notificationprofiles_check_nagios_object_version()==NDO_ERROR)
		return -1;

	/* process arguments */
	if(opsview_notificationprofiles_process_module_args(args)==NDO_ERROR)
		return -1;

	/* do some initialization stuff... */
	if(opsview_notificationprofiles_init()==NDO_ERROR)
		return -1;

	return 0;
        }


/* this function gets called when the module is unloaded by the event broker */
int nebmodule_deinit(int flags, int reason){
	char temp_buffer[OPSVIEW_NOTIFICATIONPROFILES_MAX_BUFLEN];

	/* do some shutdown stuff... */
	opsview_notificationprofiles_deinit();
	
	/* log a message to the Nagios log file */
	snprintf(temp_buffer,sizeof(temp_buffer)-1,"opsview_notificationprofiles: Shutdown complete.\n");
	temp_buffer[sizeof(temp_buffer)-1]='\x0';
        opsview_notificationprofiles_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);

	return 0;
        }



/****************************************************************************/
/* INIT/DEINIT FUNCTIONS                                                    */
/****************************************************************************/

/* checks to make sure Nagios object version matches what we know about */
int opsview_notificationprofiles_check_nagios_object_version(void){
	char temp_buffer[OPSVIEW_NOTIFICATIONPROFILES_MAX_BUFLEN];
	
	if(__nagios_object_structure_version!=CURRENT_OBJECT_STRUCTURE_VERSION){

		snprintf(temp_buffer,sizeof(temp_buffer)-1,"opsview_notificationprofiles: I've been compiled with support for revision %d of the internal Nagios object structures, but the Nagios daemon is currently using revision %d.  I'm going to unload so I don't cause any problems...\n",CURRENT_OBJECT_STRUCTURE_VERSION,__nagios_object_structure_version);
		temp_buffer[sizeof(temp_buffer)-1]='\x0';
		opsview_notificationprofiles_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);

		return NDO_ERROR;
	        }

	return NDO_OK;
        }


/* performs some initialization stuff */
int opsview_notificationprofiles_init(void){
	char temp_buffer[OPSVIEW_NOTIFICATIONPROFILES_MAX_BUFLEN];
	time_t current_time;

	/* register callbacks */
	if(opsview_notificationprofiles_register_callbacks()==NDO_ERROR)
		return NDO_ERROR;

	return NDO_OK;
        }


/* performs some shutdown stuff */
int opsview_notificationprofiles_deinit(void){
	/* deregister callbacks */
	opsview_notificationprofiles_deregister_callbacks();

	return NDO_OK;
        }



/****************************************************************************/
/* CONFIG FUNCTIONS                                                         */
/****************************************************************************/

/* process arguments that were passed to the module at startup */
int opsview_notificationprofiles_process_module_args(char *args){
	char *ptr=NULL;
	char **arglist=NULL;
	char **newarglist=NULL;
	int argcount=0;
	int memblocks=64;
	int arg=0;
    int is_master=0;

	if(args==NULL)
		return NDO_OK;

	return NDO_OK;
        }





/****************************************************************************/
/* UTILITY FUNCTIONS                                                        */
/****************************************************************************/

/* writes a string to Nagios logs */
int opsview_notificationprofiles_write_to_logs(char *buf, int flags){

	if(buf==NULL)
		return NDO_ERROR;

	return write_to_all_logs(buf,flags);
	}



/****************************************************************************/
/* CALLBACK FUNCTIONS                                                       */
/****************************************************************************/

/* registers for callbacks */
int opsview_notificationprofiles_register_callbacks(void){
	int priority=10;
	int result=NDO_OK;

    if(result==NDO_OK)
        result=neb_register_callback(NEBCALLBACK_NOTIFICATION_DATA,opsview_notificationprofiles_module_handle,priority,opsview_notificationprofiles_broker_data);
	if(result==NDO_OK)
		result=neb_register_callback(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,opsview_notificationprofiles_module_handle,priority,opsview_notificationprofiles_broker_data);

	return result;
        }


/* deregisters callbacks */
int opsview_notificationprofiles_deregister_callbacks(void){
	neb_deregister_callback(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,opsview_notificationprofiles_broker_data);
	neb_deregister_callback(NEBCALLBACK_NOTIFICATION_DATA,opsview_notificationprofiles_broker_data);
	return NDO_OK;
        }


static int opsview_notificationprofiles_notification_contact_compare(const void *p1, const void *p2){
	notification *n1 = *(notification **)p1;
	notification *n2 = *(notification **)p2;
	return strcmp(n1->contact->name, n2->contact->name);
	}

int opsview_notificationprofiles_sort_by_contacts(void){
	notification **array, *temp_notification;
	int i = 0;
    int total=0;

    temp_notification=notification_list;
    while(temp_notification!=NULL) {
        total++;
        temp_notification=temp_notification->next;
    }

    if(total==0) {
        return OK;
    }

	if(!(array=malloc(sizeof(*array)*total)))
		return ERROR;
    temp_notification=notification_list;
	while(temp_notification && i<total){
		array[i++]=temp_notification;
		temp_notification=temp_notification->next;
	}

	qsort((void *)array, i, sizeof(*array), opsview_notificationprofiles_notification_contact_compare);
	notification_list = temp_notification = array[0];
	for (i=1; i<total;i++){
		temp_notification->next = array[i];
		temp_notification=temp_notification->next;
		}
	temp_notification->next = NULL;
	my_free(array);
	return OK;
	}

/* handles brokered event data */
int opsview_notificationprofiles_broker_data(int event_type, void *data){
    opsview_notificationprofiles_method *temp_method=NULL,*next_method=NULL,*new_method=NULL;
    opsview_notificationprofiles_user   *temp_user=NULL,*next_user=NULL,*new_user=NULL;
	nebstruct_contact_notification_method_data *ecdata=NULL;
    nebstruct_notification_data *notification_data=NULL;
    char *this_methodname=NULL,*this_username=NULL;
    char *c;
    int result;

	if(data==NULL)
		return 0;

	switch(event_type){

    case NEBCALLBACK_NOTIFICATION_DATA:
        notification_data = (nebstruct_notification_data *)data;
        if (notification_data->type == NEBTYPE_NOTIFICATION_START) {
            // Sort the notification_list
            opsview_notificationprofiles_users_list=NULL;
            if((result=opsview_notificationprofiles_sort_by_contacts())==OK)
                return 0;
            else
                return NDO_ERROR;
        } else if (notification_data->type == NEBTYPE_NOTIFICATION_END) {
            // Free saved information for this notification
            for(temp_user=opsview_notificationprofiles_users_list;temp_user!=NULL;temp_user=next_user){
                for(temp_method=temp_user->methods;temp_method!=NULL;temp_method=next_method) {
                    next_method=temp_method->next;
                    my_free(temp_method->name);
                    my_free(temp_method);
                }
                next_user=temp_user->next;
                my_free(temp_user->name);
                my_free(temp_user);
            }
            opsview_notificationprofiles_users_list=NULL;
        }
        
	case NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA:

		ecdata=(nebstruct_contact_notification_method_data *)data;

		if (ecdata->type != NEBTYPE_CONTACTNOTIFICATIONMETHOD_START) {
			return 0;
		}


		this_methodname=ecdata->command_name;
        this_username = strdup(ecdata->contact_name);
        c=strchr(this_username, '/');
        if (c!=NULL) {
            *c='\0';
        }

#if DEBUG
        char *temp_buffer=NULL;
        asprintf(&temp_buffer,"Notification for method=%s, contact_name=%s, username=%s\n",this_methodname,ecdata->contact_name,this_username);
        opsview_notificationprofiles_write_to_logs(temp_buffer,NSLOG_INFO_MESSAGE);
        my_free(temp_buffer);
#endif

        for(temp_user=opsview_notificationprofiles_users_list;temp_user!=NULL;temp_user=temp_user->next) {
            if(!strcmp(temp_user->name,this_username)) {
                for(temp_method=temp_user->methods;temp_method!=NULL;temp_method=temp_method->next) {
                    if(!strcmp(temp_method->name,this_methodname)) {
                        my_free(this_username);
                        return NEBERROR_CALLBACKOVERRIDE;
                    }
                }
                /* Found user but no method setup */
                goto BREAK;
            }
        }

BREAK:
        /* User & method not found. Add the user if not found */
        if(temp_user==NULL) {
            /* Create user */
            if((new_user=malloc(sizeof(opsview_notificationprofiles_user)))==NULL) {
                my_free(this_username);
                return NDO_ERROR;
            }
            new_user->name=strdup(this_username);
            new_user->methods=NULL;

            /* Add to head of list */
            new_user->next=opsview_notificationprofiles_users_list;
            opsview_notificationprofiles_users_list=new_user;

            temp_user=new_user;
        }

        /* Add method */
        if((new_method=malloc(sizeof(opsview_notificationprofiles_method)))==NULL) {
            my_free(this_username);
            return NDO_ERROR;
        }
        new_method->name=strdup(this_methodname);
        new_method->next=temp_user->methods;
        temp_user->methods=new_method;

        my_free(this_username);
        return 0;
		break;

	default:
		return 0;
		break;
	        }

	return 0;
        }



