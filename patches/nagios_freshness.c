/*****************************************************************************
 *
 * FRESHNESS.C - Freshness functions for Nagios
 *
 * Copyright (c) 1999-2007 Ethan Galstad (nagios@nagios.org)
 * Last Modified:   04-10-2006
 *
 * License:
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 *
 *****************************************************************************/

#include "../include/objects.h"
#include "../include/nagios.h"
#include "../include/common.h"

extern int      interval_length;
extern int      additional_freshness_latency;

extern time_t   program_start;

int calculate_service_freshness_threshold(service *svc){
	int temp_threshold;

	/* use user-supplied freshness threshold or auto-calculate a freshness threshold to use? */
	if(svc->freshness_threshold==0){
		if(svc->state_type==HARD_STATE || svc->current_state==STATE_OK)
			temp_threshold=(svc->check_interval*interval_length)+svc->latency+additional_freshness_latency;
		else
			temp_threshold=(svc->retry_interval*interval_length)+svc->latency+additional_freshness_latency;
		/* Push threshold a bit larger over a program start to allow for missing results in a distributed setup
		 * Sets an arbitrary 1 hour threshold on the check interval of services that are pushed because
		 * if the check_interval is a day and a reload occurs at least once a day, the service would never
		 * go stale. A reload every hour is unlikely */
		if(svc->has_been_checked==TRUE && program_start>svc->last_check && svc->check_interval*interval_length<=3600)
			temp_threshold=temp_threshold+(int)(program_start-svc->last_check);
		}
	else
		temp_threshold=svc->freshness_threshold;

#ifdef TEST_FRESHNESS
	printf("THRESHOLD: SVC=%d, USE=%d\n",svc->freshness_threshold,temp_threshold);
#endif

	return temp_threshold;
}

int calculate_host_freshness_threshold(host *hst){
	int temp_threshold;

	if(hst->freshness_threshold==0){
		temp_threshold=(hst->check_interval*interval_length)+hst->latency+additional_freshness_latency;
		if(hst->has_been_checked==TRUE && program_start>hst->last_check)
			temp_threshold=temp_threshold+(int)(program_start-hst->last_check);
		}
	else
		temp_threshold=hst->freshness_threshold;

	return temp_threshold;
}
