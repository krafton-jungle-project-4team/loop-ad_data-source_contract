CREATE NAMED COLLECTION IF NOT EXISTS loopad_events_kafka AS
    kafka_broker_list = '<KAFKA_BOOTSTRAP_BROKERS>' NOT OVERRIDABLE,
    kafka_topic_list = 'loop-ad.events.raw' NOT OVERRIDABLE,
    kafka_group_name = 'loopad-clickhouse-events' NOT OVERRIDABLE,
    kafka_format = 'JSONEachRow' NOT OVERRIDABLE,
    kafka_security_protocol = 'sasl_plaintext' NOT OVERRIDABLE,
    kafka_sasl_mechanism = 'SCRAM-SHA-512' NOT OVERRIDABLE,
    kafka_sasl_username = '<KAFKA_APP_USERNAME>' NOT OVERRIDABLE,
    kafka_sasl_password = '<KAFKA_APP_PASSWORD>' NOT OVERRIDABLE;
