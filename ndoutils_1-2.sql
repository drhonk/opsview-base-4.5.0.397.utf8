ALTER TABLE nagios_hostchecks ADD long_output TEXT NOT NULL default '';

ALTER TABLE nagios_hoststatus ADD long_output TEXT NOT NULL default '',
    ADD KEY `status_update_time` (`status_update_time`),
    ADD KEY `current_state` (`current_state`),
    ADD KEY `check_type` (`check_type`),
    ADD KEY `state_type` (`state_type`),
    ADD KEY `last_state_change` (`last_state_change`),
    ADD KEY `notifications_enabled` (`notifications_enabled`),
    ADD KEY `problem_has_been_acknowledged` (`problem_has_been_acknowledged`),
    ADD KEY `active_checks_enabled` (`active_checks_enabled`),
    ADD KEY `passive_checks_enabled` (`passive_checks_enabled`),
    ADD KEY `event_handler_enabled` (`event_handler_enabled`),
    ADD KEY `flap_detection_enabled` (`flap_detection_enabled`),
    ADD KEY `is_flapping` (`is_flapping`),
    ADD KEY `percent_state_change` (`percent_state_change`),
    ADD KEY `latency` (`latency`),
    ADD KEY `execution_time` (`execution_time`),
    ADD KEY `scheduled_downtime_depth` (`scheduled_downtime_depth`);

ALTER TABLE nagios_notifications ADD `long_output` TEXT NOT NULL default '';

ALTER TABLE nagios_servicechecks ADD `long_output` TEXT NOT NULL default '';

ALTER TABLE nagios_servicestatus ADD `long_output` TEXT NOT NULL default '',
    ADD KEY `status_update_time` (`status_update_time`),
    ADD KEY `current_state` (`current_state`),
    ADD KEY `check_type` (`check_type`),
    ADD KEY `state_type` (`state_type`),
    ADD KEY `last_state_change` (`last_state_change`),
    ADD KEY `notifications_enabled` (`notifications_enabled`),
    ADD KEY `problem_has_been_acknowledged` (`problem_has_been_acknowledged`),
    ADD KEY `active_checks_enabled` (`active_checks_enabled`),
    ADD KEY `passive_checks_enabled` (`passive_checks_enabled`),
    ADD KEY `event_handler_enabled` (`event_handler_enabled`),
    ADD KEY `flap_detection_enabled` (`flap_detection_enabled`),
    ADD KEY `is_flapping` (`is_flapping`),
    ADD KEY `percent_state_change` (`percent_state_change`),
    ADD KEY `latency` (`latency`),
    ADD KEY `execution_time` (`execution_time`),
    ADD KEY `scheduled_downtime_depth` (`scheduled_downtime_depth`);

ALTER TABLE nagios_timedeventqueue
    ADD KEY `event_type` (`event_type`),
    ADD KEY `scheduled_time` (`scheduled_time`),
    ADD KEY `object_id` (`object_id`);

ALTER TABLE nagios_timedevents
    ADD KEY `event_type` (`event_type`),
    ADD KEY `scheduled_time` (`scheduled_time`),
    ADD KEY `object_id` (`object_id`);
