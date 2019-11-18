# Flexible Postgres output for fluentd

An output plugin for [fluentd](https://www.fluentd.org/) for use with [Postgres](https://www.postgresql.org/) and [TimescaleDB](https://www.timescale.com/) that provides a great amount of flexibility in designing your log table structure.

This plugin automatically reads your log table's schema and maps log record properties to dedicated columns if possible. All other properties will be stored in an _extra_ column of type `json` or `jsonb`. This plugin also handles Porstgres `enum` types, it will try to map string properties to enum columns.

Consider following log table:

```sql
CREATE TYPE Severity AS ENUM (
	'debug',
	'info',
	'notice',
	'warning',
	'error',
	'alert',
	'emergency'
);

CREATE TABLE public.logs (
	time TIMESTAMPTZ NOT NULL,
	severity Severity NOT NULL DEFAULT 'info',
	message TEXT NULL,
	extra JSONB NULL
);
```

And a log event of the form:

```
time   2019-10-10 10:01:20.1234
tag    'backend'
record {"severity":"notice","message":"Starting up...","hostname":"node0123","meta":{"env":"production"}}
```

You will end up with this row inserted:

| time | severity | message    | extra                                              |
|------|----------|------------|----------------------------------------------------|
| `2019-10-10 10:01:20.1234` | notice | Starting up... | `{"hostname":"node0123", "meta":{"env":"production"}}`

The properties `severity` and `message` where mapped to their dedicated columns, all other properties landed in the `extra` column.

__Note:__ The event's tag is not used in any way. I consider the tag an implementation detail of fluentd's routing system, that should not be used elsewhere. If the tag contains valuable data in your setup, you can include it as property with the `record_transformer` plugin.


## Requirements

- The `pg` Gem and it's native library.
- A time column of type `timestamp with timezone` or `timezone without timezone` in your log table.
- An _extra_ column of type `json` or `jsonb` to store all values without a dedicated column.


## Configuration

- __`host`__ (string, default: `localhost`)<br>
    The database server's hostname.

- __`port`__ (integer, default: `5432`)<br>
    The database server's port.

- __`database`__ (string)<br>
    The database name.

- __`username`__ (string)<br>
    The database user name.

- __`password`__ (string)<br>
    The database user's password.

- __`table`__ (string)<br>
    The name of the log table.

- __`time_column`__ (string, default: `time`)<br>
    The column name to store the timestamp of log events. Must be of type `timestamp with timezone` or `timezone without timezone`.

- __`extra_column`__ (string, default: `extra`)<br>
    The column name to store excess properties without a dedicated column. Must be of type `json` or `jsonb`.


## Value coercion

This plugin tries to coerce all values in a meaningful way

| column type  | value type | coercion rule                                                     |
|-             |-           |-                                                                  |
| timestamp    | `string`   | Parse as RFC3339 string                                           |
|              | `number`   | Interpret as seconds since Unix epoch (with fractions)            |
|              | _others_   | _undefined, place in extra columns_                               |
| text         | _all_      | Convert to JSON string                                            |
| boolean      | `string`   | Interpret `"t"`, `"true"` (any case) as `true`, `false` otherwise |
|              | `number`   | Interpret `0` as `false`, other values as `true`                  |
|              | _others_   | _undefined, place in extra columns_                               |
| real numbers | `boolean`  | Interpret `true` as `1.0`, `false` as `0.0`                       |
|              | `string`   | Parse as decimal (with fractions)                                 |
|              | _others_   | _undefined, place in extra columns_                               |
| integers     | `boolean`  | Interpret `true` as `1`, `false` as `0`                           |
|              | `string`   | Parse as decimal (without fractions)                              |
| json         | _all_      | Convert to JSON string                                            |


## Log table design considerations

- Since you want to avoid losing log events, your log table should be designed in a way that it is
(almost) impossible to error at inserting data. This means that all columns should be either _nullable_ or provide a default value. The only exception is the time column, which is guaranteed to be filled with the event's time stamp.

- You may or may not need a primary key. For general use, a primary key is not really necessary, since you `select` and `delete` events only in bulk, not individually.

- Keep that in mind that the `timestamp` value type provides microsecond precision. This is good enough for many use cases but might not be enough for yours.
