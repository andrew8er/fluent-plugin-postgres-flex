require 'fluent/plugin/output'
require 'fluent/time'
require 'pg'
require 'oj'
require 'date'

module Fluent::Plugin
	class PostgresFlexOutput < Output
		Fluent::Plugin.register_output('postgres-flex', self)

		config_param :host, :string, default: 'localhost'
		config_param :port, :integer, default: 5432
		config_param :database, :string
		config_param :username, :string
		config_param :password, :string
		config_param :table, :string
		config_param :time_column, :string, default: 'time'
		config_param :extra_column, :string, default: 'extra'

		config_section :buffer do
			config_set_default :flush_mode, :immediate
		end

		TimestampFormat = '%Y-%m-%d %H:%M:%S.%N %z'
		TimestampFormatter = Fluent::TimeFormatter.new(TimestampFormat)
		OjOptions = { mode: :strict }

		def start
			super
			reconnect()
		end

		def stop
			super
			@db.finish
		end

		def write(chunk)
			values = []
			chunk.each { |time, record| values << record_to_values(time, record) }

			begin
				@db.async_exec("INSERT INTO #{ @db.quote_ident(@table) } #{ @value_names } VALUES #{ values.join(',') }")
			rescue PG::UnableToSend => err
				reconnect()
				throw err
			end
		end

		private

		def reconnect
			@db = PG::Connection.new(
				:host => @host,
				:port => @port,
				:dbname => @database,
				:user => @username,
				:password => @password
			)
			@schema, @value_names = parse_schema(@db)
		end

		# Convert a single record to a postgres value string
		#
		# All values that have a dedicated column will be coerced and stored there. If coercion fails,
		# the value will be retained in the _extra_ column and the default value will be used.
		def record_to_values(eventTime, record)
			direct_fields = []

			@schema.each_pair { |key, type|
				value = coerce_value(record[key], type)

				if value.nil?
					log.warn "Could not coerce value #{record[key].inspect} to required type #{type.inspect}"
				else
					direct_fields << value
					record.delete(key)
				end
			}

			time = @db.escape_literal(TimestampFormatter.format_with_subsec(eventTime))
			extras = @db.escape_literal(Oj.dump(record, OjOptions))

			return "(#{ time },#{ direct_fields.join(',') },#{ extras })"
		end

		# Coerce a single value to the type requiered by the database column
		#
		# @return The coerced value or nil, if the value could not be coerced
		def coerce_value(v, type)
			if v.nil?
				'DEFAULT'
			else
				case type
				when :timestamp
					case v
					when String
						# Parse as RFC3339
						@db.escape_literal(DateTime.rfc3339(v).to_time.utc.strfrm(TimestampFormat))
					when Numeric
						# Interpret as Unix time: seconds (with fractions) since epoch
						@db.escape_literal(Time.at(v).utc.strfrm(TimestampFormat))
					else nil
					end
				when :string
					@db.escape_literal(Oj.dump(v, OjOptions))
				when :boolean
					case v
					when TrueClass; 'true'
					when FalseClass; 'false'
					when String
						# Accept 't', 'T', 'true', 'TRUE', 'True'..., 1 as true, false otherwise
						(v.downcase == 't' || v.downcase == 'true' || v == '1').to_s
					when Numeric
						v != 0
					else nil
					end
				when :integer
					case v
					when TrueClass; '1' # Accept true as 1
					when FalseClass; '0' # Accept false as 0
					when String; v.to_i(10).to_s # Parse string as decimal
					when Integer; v.to_s
					else nil
					end
				when :float
					case
					when Float; v.to_s
					when String; v.to_f.to_s # Parse string as float
					else nil
					end
				when :json
					begin
						@db.escape_literal(Oj.dump(v, OjOptions))
					rescue Oj::Error => e
						# TODO log this
						nil
					end
				when Array # enums
					return @db.escape_literal(v) if type.include?(v)
				else nil
				end
			end
		end

		# Parse postgres database schema and build a hash of column_name => type
		def parse_schema(db)
			# Map enum_name: String => enum_values: String[]
			enums = db.async_exec(
				'SELECT DISTINCT (n.nspname||\'.\'||t.typname) AS "name", e.enumlabel as "value"' +
				'	FROM pg_type t' +
				'	JOIN pg_enum e on t.oid = e.enumtypid' +
				'	JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace'
			).reduce({}) { |map, row|
				name = row['name']
				map[name] = [] unless map[name]
				map[name] << row['value']

				map
			}

			# Map column_name: String => type: Symbol|String[]
			schema = db.async_exec(
				'SELECT column_name, ' +
				'	(CASE WHEN data_type != \'USER-DEFINED\' THEN data_type ELSE (udt_schema||\'.\'||udt_name) END) as "type"' +
				"	FROM information_schema.columns WHERE table_name = #{ @db.escape_literal(@table) }"
			).reduce({}) { |map, row|
				name = row['column_name']
				type = case row['type']
					when 'timestamp with time zone'; :timestamp
					when 'timestamp without time zone'; :timestamp
					when 'text'; :string
					when 'character varying'; :string
					when 'character'; :string
					when 'boolean'; :boolean
					when 'smallint'; :integer
					when 'integer'; :integer
					when 'bigint'; :integer
					when 'decimal'; :float
					when 'numeric'; :float
					when 'real'; :float
					when 'double precision'; :float
					when 'json'; :json
					when 'jsonb'; :json
					else enums[row['type']] # Is enum?
				end

				if type.nil?
					log.warn "Unhandled column type '#{type}'"
				else
					if name == @time_column
						if type != :timestamp
							raise Fluent::ConfigError.new('time column must be of type "timestamp with/without timestamp"')
						end
					elsif name == @extra_column
						if type != :json
							raise Fluent::ConfigError.new('extra column must be of type "json/jsonb"')
						end
					else
						map[name] = type
					end
				end

				map
			}

			value_names = "(#{ @time_column },#{ schema.keys.join(',') },#{ @extra_column })"

			return schema.freeze, value_names.freeze
		end
	end
end
