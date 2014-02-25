ALTER TABLE `nagios_notifications` ADD `notification_number` SMALLINT( 6 ) DEFAULT '0' NOT NULL AFTER `notification_reason`;
