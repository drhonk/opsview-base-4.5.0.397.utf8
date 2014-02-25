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
#include "../include/opsview_distributed_notifications.h"
#include "../include/nagios-4x/nebstructs.h"
#include "../include/nagios-4x/nebmodules.h"
#include "../include/nagios-4x/nebcallbacks.h"
#include "../include/nagios-4x/broker.h"
#include "../include/nagios-4x/neberrors.h"
#include "tap.h"

int write_to_all_logs(char *string,unsigned long facility) {}
int neb_deregister_callback(int callback_type, int (*callback_func)(int,void *)) {}
int neb_register_callback(int callback_type, void *mod_handle, int priority, int (*callback_func)(int,void *)) {}

extern opsview_distributed_notifications_methods *opsview_distributed_notifications_methods_list;
//extern int opsview_distributed_notifications_is_master=0;
int __nagios_object_structure_version=1;

int
main (int argc, char **argv)
{
    opsview_distributed_notifications_methods *temp_nm;
    nebstruct_contact_notification_method_data *neb_nm;
    host *temp_host=NULL, *temp_host_on_master=NULL, *temp_host_on_slave=NULL;
    service *temp_service=NULL, *temp_service_on_master=NULL, *temp_service_on_slave=NULL;
    contactgroupsmember *temp_contactgroupsmember=NULL;

    char *args=NULL;

	plan_tests(55);

    ok(opsview_distributed_notifications_methods_list==NULL, "List empty");

    /* Testing case:
    On master server
    SMS by master
    Email by monitored_by
    1) hostonmaster    alerts => sms and email
    2) serviceonmaster alerts => sms and email
    3) hostonslave     alerts => sms and no email
    4) serviceonslave  alerts => sms and no email
    */
    args=strdup("master=1,master-contactgroup=ov_monitored_by_master,notify-by-sms=master,notify-by-email=ov_monitored_by_master");
    opsview_distributed_notifications_process_module_args( args );

    ok(opsview_distributed_notifications_methods_list!=NULL, "List now populated");
    temp_nm=opsview_distributed_notifications_methods_list;
    ok(temp_nm!=NULL, "Have 1st notification method (order reversed)" );
    ok(!strcmp(temp_nm->name,"notify-by-email"), "Email");
    ok(temp_nm->action==2, "Use contact group name" );
    ok(!strcmp(temp_nm->contactgroupname,"ov_monitored_by_master"), "Found contactgroup name");

    temp_nm=temp_nm->next;
    ok(!strcmp(temp_nm->name,"notify-by-sms"), "Right name" ) || diag("Name:%s\n", temp_nm->name);
    ok(temp_nm->action==1, "Master flag set");
    ok(temp_nm->contactgroupname==NULL, "No contactgroups required" );

    ok(temp_nm->next==NULL, "No more notification methods");

    /* Setup fixtures */
    temp_contactgroupsmember=malloc(sizeof(contactgroupsmember));
    temp_contactgroupsmember->group_name = strdup("ov_monitored_by_master");
    temp_contactgroupsmember->next=NULL;

    temp_host=malloc(sizeof(host));
    temp_host->contact_groups=temp_contactgroupsmember;

    temp_service=malloc(sizeof(service));
    temp_service->contact_groups=temp_contactgroupsmember;

    neb_nm=malloc(sizeof(nebstruct_contact_notification_method_data));
    neb_nm->type=NEBTYPE_CONTACTNOTIFICATIONMETHOD_START;
    neb_nm->service_description=NULL;
    neb_nm->object_ptr=temp_host;

    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==NEBERROR_CALLBACKBOUNDS, "Expected error");


    /* Case 1 */
    neb_nm->command_name=strdup("notify-by-sms");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Host monitored by master: SMS okay");

    neb_nm->command_name=strdup("notify-by-email");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Host monitored by master: Email okay");

    neb_nm->command_name=strdup("notify-by-somethingelse");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Host monitored by master: unseen notification method okay");



    /* Case 2 */
    neb_nm->service_description="A service";
    neb_nm->object_ptr=temp_service;
    neb_nm->state=STATE_CRITICAL;

    neb_nm->command_name=strdup("notify-by-sms");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Service monitored by master: SMS okay");

    neb_nm->command_name=strdup("notify-by-email");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Service monitored by master: Email okay");

    neb_nm->command_name=strdup("notify-by-somethingelse");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Service monitored by master: unseen notification method okay");


    /* Case 2b - confirm unknown state doesn't make a difference */
    neb_nm->state=STATE_UNKNOWN;

    neb_nm->command_name=strdup("notify-by-sms");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Service monitored by master: SMS okay");

    neb_nm->command_name=strdup("notify-by-email");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Service monitored by master: Email okay");

    neb_nm->command_name=strdup("notify-by-somethingelse");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Service monitored by master: unseen notification method okay");



    /* Case 3 - host monitored by slave changed by removing ov_monitored_by_master */
    neb_nm->service_description=NULL;
    neb_nm->object_ptr=temp_host;
    temp_host->contact_groups=NULL;

    neb_nm->command_name=strdup("notify-by-sms");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, 
        "Host monitored by slave SMS okay");

    neb_nm->command_name=strdup("notify-by-email");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==NEBERROR_CALLBACKOVERRIDE, 
        "Host monitored by slave Email ignored");

    neb_nm->command_name=strdup("notify-by-somethingelse");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, 
        "Host monitored by slave unseen notification method okay");


    
    /* Case 4 - service monitored by slave (set by removing ov_monitored_by_master contactgroup) */
    neb_nm->service_description="Something";
    neb_nm->object_ptr=temp_service;
    temp_service->contact_groups=NULL;
    neb_nm->state=STATE_CRITICAL;

    neb_nm->command_name=strdup("notify-by-sms");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, 
        "Service monitored by slave SMS okay");

    neb_nm->command_name=strdup("notify-by-email");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==NEBERROR_CALLBACKOVERRIDE, 
        "Service monitored by slave Email ignored");

    neb_nm->command_name=strdup("notify-by-somethingelse");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, 
        "Service monitored by slave unseen notification method okay");


    /* Case 4b - where state is UNKNOWN, monitored by slave */
    neb_nm->state=STATE_UNKNOWN;

    neb_nm->command_name=strdup("notify-by-sms");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==NEBERROR_CALLBACKOVERRIDE, 
        "Service monitored by slave SMS ignored due to master ignoring unknowns");

    neb_nm->command_name=strdup("notify-by-email");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==NEBERROR_CALLBACKOVERRIDE, 
        "Service monitored by slave Email ignored");

    neb_nm->command_name=strdup("notify-by-somethingelse");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, 
        "Service monitored by slave unseen notification method okay");






    
    /* Testing case:
    On slave server
    SMS by master
    Email by monitored_by
    1) host    alerts => no sms and email
    2) service alerts => no sms and email
    */
    opsview_distributed_notifications_deinit();
    ok(opsview_distributed_notifications_methods_list==NULL, "List cleared");

    args=strdup("master=0,notify-by-sms=master");
    opsview_distributed_notifications_process_module_args( args );

    ok(opsview_distributed_notifications_methods_list!=NULL, "List now populated");
    temp_nm=opsview_distributed_notifications_methods_list;
    ok(temp_nm!=NULL, "Have 1st notification method (order reversed)" );
    ok(!strcmp(temp_nm->name,"notify-by-sms"), "SMS") || diag("name=%s\n", temp_nm->name);
    ok(temp_nm->action==0, "Master notified") || diag("action=%d\n", temp_nm->action);
    ok(temp_nm->contactgroupname==NULL, "No contactgroups required" );
    ok(temp_nm->next==NULL, "No more notification methods");

    /* Setup fixtures */
    temp_contactgroupsmember=malloc(sizeof(contactgroupsmember));
    temp_contactgroupsmember->group_name = strdup("strangething");
    temp_contactgroupsmember->next=NULL;

    temp_host=malloc(sizeof(host));
    temp_host->contact_groups=temp_contactgroupsmember;

    temp_service=malloc(sizeof(service));
    temp_service->contact_groups=temp_contactgroupsmember;

    neb_nm=malloc(sizeof(nebstruct_contact_notification_method_data));
    neb_nm->type=NEBTYPE_CONTACTNOTIFICATIONMETHOD_START;
    neb_nm->service_description=NULL;
    neb_nm->object_ptr=temp_host;


    /* Case 1 */
    neb_nm->command_name=strdup("notify-by-sms");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==NEBERROR_CALLBACKOVERRIDE, 
        "Host monitored by slave: SMS blocked");

    neb_nm->command_name=strdup("notify-by-email");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, 
        "Host monitored by slave: Email okay");


    /* Case 2 */
    neb_nm->service_description="A service";
    neb_nm->object_ptr=temp_service;
    neb_nm->state=STATE_CRITICAL;

    neb_nm->command_name=strdup("notify-by-sms");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==NEBERROR_CALLBACKOVERRIDE, 
        "Service monitored by slave: SMS blocked");

    neb_nm->command_name=strdup("notify-by-email");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, 
        "Service monitored by slave: Email okay");


    /* Case 2b - confirm unknowns are not a blocked */
    neb_nm->state=STATE_UNKNOWN;

    neb_nm->command_name=strdup("notify-by-sms");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==NEBERROR_CALLBACKOVERRIDE, 
        "Service monitored by slave: SMS blocked");

    neb_nm->command_name=strdup("notify-by-email");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, 
        "Service monitored by slave: Email okay");







    /* Testing case:
    On master server
    SMS by master
    Email by monitored_by
    1) host    alerts => no sms and email
    2) service alerts => no sms and email
    */
    opsview_distributed_notifications_deinit();
    ok(opsview_distributed_notifications_methods_list==NULL, "List cleared");

    args=strdup("master=1,notify-by-sms=master");
    opsview_distributed_notifications_process_module_args( args );

    ok(opsview_distributed_notifications_methods_list!=NULL, "List now populated");
    temp_nm=opsview_distributed_notifications_methods_list;
    ok(temp_nm!=NULL, "Have 1st notification method (order reversed)" );
    ok(!strcmp(temp_nm->name,"notify-by-sms"), "SMS") || diag("name=%s\n", temp_nm->name);
    ok(temp_nm->action==1, "Master is notifier") || diag("action=%d\n", temp_nm->action);
    ok(temp_nm->contactgroupname==NULL, "No contactgroups required" );
    ok(temp_nm->next==NULL, "No more notification methods");

    /* Setup fixtures */
    temp_contactgroupsmember=malloc(sizeof(contactgroupsmember));
    temp_contactgroupsmember->group_name = strdup("strangething");
    temp_contactgroupsmember->next=NULL;

    temp_host=malloc(sizeof(host));
    temp_host->contact_groups=temp_contactgroupsmember;

    temp_service=malloc(sizeof(service));
    temp_service->contact_groups=temp_contactgroupsmember;

    neb_nm=malloc(sizeof(nebstruct_contact_notification_method_data));
    neb_nm->type=NEBTYPE_CONTACTNOTIFICATIONMETHOD_START;
    neb_nm->service_description=NULL;
    neb_nm->object_ptr=temp_host;

    /* Case 1 */
    neb_nm->command_name=strdup("notify-by-sms");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Host monitored by master: SMS okay");

    neb_nm->command_name=strdup("notify-by-email");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, 
        "Host monitored by slave: Email okay");


    /* Case 2 */
    neb_nm->service_description="A service";
    neb_nm->object_ptr=temp_service;
    neb_nm->state=STATE_CRITICAL;

    neb_nm->command_name=strdup("notify-by-sms");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Host monitored by master: SMS okay");

    neb_nm->command_name=strdup("notify-by-email");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, 
        "Service monitored by slave: Email okay");


    /* Case 2b - confirm unknowns are not a blocked */
    neb_nm->state=STATE_UNKNOWN;

    neb_nm->command_name=strdup("notify-by-sms");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, "Host monitored by master: SMS okay");

    neb_nm->command_name=strdup("notify-by-email");
    ok(opsview_distributed_notifications_broker_data(NEBCALLBACK_CONTACT_NOTIFICATION_METHOD_DATA,(void *)neb_nm)==0, 
        "Service monitored by slave: Email okay");


	return exit_status ();
}
