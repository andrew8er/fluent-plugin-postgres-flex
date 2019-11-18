Gem::Specification.new do |s|
	s.name = 'fluent-plugin-postgres-flex'
	s.version = '0.1.0.rc1'
	s.licenses = ['Apache-2.0']
	s.summary = "A fluentd plugin for storing logs in Postgres and TimescaleDB"
	s.description = "Store fluentd structured log data in Postgres and TimescaleDB."
	s.authors = [
		"André Wachter"
	]
	s.email = 'rubygems@anfe.ma'
	s.homepage = 'https://github.com/anfema/fluent-plugin-postgres-flex'
	s.metadata = {
		"source_code_uri" => "https://github.com/anfema/fluent-plugin-postgres-flex"
	}
	s.files = Dir[
		"lib/**/*.rb",
		"License",
		"*.md"
	]
end