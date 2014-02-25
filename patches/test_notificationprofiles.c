/*****************************************************************************
* 
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
* 
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
* 
* You should have received a copy of the GNU General Public License
* along with this program.  If not, see <http://www.gnu.org/licenses/>.
* 
* 
*****************************************************************************/

#include "../include/config.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "../include/opsview_notificationprofiles.h"
#include "../include/nagios-4x/nebstructs.h"
#include "../include/nagios-4x/nebmodules.h"
#include "../include/nagios-4x/nebcallbacks.h"
#include "../include/nagios-4x/broker.h"
#include "../include/nagios-4x/neberrors.h"
#include "tap.h"

int write_to_all_logs(char *string,unsigned long facility) {}
int neb_deregister_callback(int callback_type, int (*callback_func)(int,void *)) {}
int neb_register_callback(int callback_type, void *mod_handle, int priority, int (*callback_func)(int,void *)) {}

extern opsview_notificationprofiles_user *opsview_notificationprofiles_users_list;

int __nagios_object_structure_version=1;

notification *notification_list=NULL;

int
main (int argc, char **argv)
{
    nebstruct_contact_notification_method_data *neb_nm;
    nebstruct_notification_data *neb_notify;
    host *temp_host=NULL, *temp_host_on_master=NULL, *temp_host_on_slave=NULL;
    service *temp_service=NULL, *temp_service_on_master=NULL, *temp_service_on_slave=NULL;
    contactgroupsmember *temp_contactgroupsmember=NULL;
    notification *temp_notification=NULL, *next_notification=NULL;
    contact *temp_contact=NULL;
    

    char *args=NULL;

	plan_tests(23);

    ok( opsview_notificationprofiles_process_module_args( args )==0, "process args ok" );


    if ((neb_notify=malloc(sizeof(nebstruct_notification_data)))==NULL) {
        diag("Failed malloc!");
        exit(1);
    }
    neb_notify->type=NEBTYPE_NOTIFICATION_START;
    notification_list=NULL;

    ok(opsview_notificationprofiles_broker_data(NEBCALLBACK_NOTIFICATION_DATA,(void *)neb_notify)==0, "Return from start okay" );

    ok(opsview_notificationprofiles_broker_data(NEBCALLBACK_NOTIFICATION_DATA,(void *)neb_notify)==0, "Run a 2nd time, because problem if 0 items" );

    temp_notification=malloc(sizeof(notification));
    notification_list=temp_notification;
    temp_contact=malloc(sizeof(contact));
    temp_contact->name = strdup("jamespeel/02sms");
    temp_notification->contact=temp_contact;

    next_notification=malloc(sizeof(notification));
    temp_notification->next=next_notification;
    temp_notification=next_notification;

    temp_contact=malloc(sizeof(contact));
    temp_contact->name = strdup("tonvoon/01email");
    temp_notification->contact=temp_contact;

    next_notification=malloc(sizeof(notification));
    temp_notification->next=next_notification;
    temp_notification=next_notification;

    temp_contact=malloc(sizeof(contact));
    temp_contact->name = strdup("jamespeel");
    temp_notification->contact=temp_contact;

    next_notification=malloc(sizeof(notification));
    temp_notification->next=next_notification;
    temp_notification=next_notification;

    temp_contact=malloc(sizeof(contact));
    temp_contact->name = strdup("tonvoon");
    temp_notification->contact=temp_contact;

    next_notification=malloc(sizeof(notification));
    temp_notification->next=next_notification;
    temp_notification=next_notification;

    temp_contact=malloc(sizeof(contact));
    temp_contact->name = strdup("tonvoon/99jabber");
    temp_notification->contact=temp_contact;

    next_notification=malloc(sizeof(notification));
    temp_notification->next=next_notification;
    temp_notification=next_notification;

    temp_contact=malloc(sizeof(contact));
    temp_contact->name = strdup("dferg/05rss");
    temp_notification->contact=temp_contact;

    next_notification=malloc(sizeof(notification));
    temp_notification->next=next_notification;
    temp_notification=next_notification;

    temp_contact=malloc(sizeof(contact));
    temp_contact->name = strdup("dferg");
    temp_notification->contact=temp_contact;
    temp_notification->next=NULL;


    //for(temp_notification=notification_list;temp_notification!=NULL;temp_notification=temp_notification->next){
    //    diag("Order: %s", temp_notification->contact->name);
    //}

    ok(opsview_notificationprofiles_broker_data(NEBCALLBACK_NOTIFICATION_DATA,(void *)neb_notify)==0, "Return from start okay with sort" );
    
    //for(temp_notification=notification_list;temp_notification!=NULL;temp_notification=temp_notification->next){
    //    diag("Order: %s", temp_notification->contact->name);
    //}

    temp_notification=notification_list;
    ok(strcmp(temp_notification->contact->name, "dferg")==0, "Got dferg first") || diag("Got %s", temp_notification->contact->name);
    temp_notification=temp_notification->next;
    ok(strcmp(temp_notification->contact->name, "dferg/05rss")==0, "Then 05rss" );
    temp_notification=temp_notification->next;
    ok(strcmp(temp_notification->contact->name, "jamespeel")==0, "jamespeel" );
    temp_notification=temp_notification->next;
    ok(strcmp(temp_notification->contact->name, "jamespeel/02sms")==0, "Then 02sms" );
    temp_notification=temp_notification->next;
    ok(strcmp(temp_notification->contact->name, "tonvoon")==0, "tonvoon" );
    temp_notification=temp_notification->next;
    ok(strcmp(temp_notification->contact->name, "tonvoon/01email")==0, "Then 01email" );
    temp_notification=temp_notification->next;
    ok(strcmp(temp_notification->contact->name, "tonvoon/99jabber")==0, "And 99rss" );
    temp_notification=temp_notification->next;
    ok(temp_notification==NULL, "No more in list" );

    neb_nm=malloc(sizeof(nebstruct_contact_notification_method_data));
    neb_nm->type=NEBTYPE_CONTACTNOTIFICATIONMETHOD_START;
    neb_nm->command_name=strdup("notify-by-aliens");
    neb_nm->contact_name=strdup("dferg");
    
    ok(opsview_notificationprofiles_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Allowed notification");

    neb_nm=malloc(sizeof(nebstruct_contact_notification_method_data));
    neb_nm->type=NEBTYPE_CONTACTNOTIFICATIONMETHOD_START;
    neb_nm->command_name=strdup("notify-by-aliens");
    neb_nm->contact_name=strdup("dferg/01sms");
    
    ok(opsview_notificationprofiles_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==NEBERROR_CALLBACKOVERRIDE, "Blocked because already seen");

    neb_nm=malloc(sizeof(nebstruct_contact_notification_method_data));
    neb_nm->type=NEBTYPE_CONTACTNOTIFICATIONMETHOD_START;
    neb_nm->command_name=strdup("notify-by-roadrunner");
    neb_nm->contact_name=strdup("dferg/01sms");
    
    ok(opsview_notificationprofiles_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Allow because of new notification method");


    neb_nm=malloc(sizeof(nebstruct_contact_notification_method_data));
    neb_nm->type=NEBTYPE_CONTACTNOTIFICATIONMETHOD_START;
    neb_nm->command_name=strdup("notify-by-roadrunner");
    neb_nm->contact_name=strdup("tonvoon/bobby");
    
    ok(opsview_notificationprofiles_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Allow" );


    neb_nm=malloc(sizeof(nebstruct_contact_notification_method_data));
    neb_nm->type=NEBTYPE_CONTACTNOTIFICATIONMETHOD_START;
    neb_nm->command_name=strdup("notify-by-roadrunner");
    neb_nm->contact_name=strdup("tonvoon/later");
    
    ok(opsview_notificationprofiles_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==NEBERROR_CALLBACKOVERRIDE, "Blocked");


    neb_nm=malloc(sizeof(nebstruct_contact_notification_method_data));
    neb_nm->type=NEBTYPE_CONTACTNOTIFICATIONMETHOD_START;
    neb_nm->command_name=strdup("notify-by-roadrunner");
    neb_nm->contact_name=strdup("jamespeel");
    
    ok(opsview_notificationprofiles_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Allow");


    neb_nm=malloc(sizeof(nebstruct_contact_notification_method_data));
    neb_nm->type=NEBTYPE_CONTACTNOTIFICATIONMETHOD_START;
    neb_nm->command_name=strdup("notify-by-roadrunner");
    neb_nm->contact_name=strdup("jamespeel/999");
    
    ok(opsview_notificationprofiles_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==NEBERROR_CALLBACKOVERRIDE, "Block");


    neb_nm=malloc(sizeof(nebstruct_contact_notification_method_data));
    neb_nm->type=NEBTYPE_CONTACTNOTIFICATIONMETHOD_START;
    neb_nm->command_name=strdup("notify-by-eskimos");
    neb_nm->contact_name=strdup("jamespeel/999");
    
    ok(opsview_notificationprofiles_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Allow");

    ok(opsview_notificationprofiles_users_list!=NULL, "List set");

    neb_notify->type=NEBTYPE_NOTIFICATION_END;
    ok(opsview_notificationprofiles_broker_data(NEBCALLBACK_NOTIFICATION_DATA,(void *)neb_notify)==0, "End of notify okay" );

    ok(opsview_notificationprofiles_users_list==NULL, "List emptied");

	return exit_status ();
}
