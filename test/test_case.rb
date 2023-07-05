# Start simplecov if this is a coverage task or if it is run in the CI pipeline
if ENV["COVERAGE"] == "true" || ENV["CI"] == "true"
  require "simplecov"
  require "simplecov-cobertura"
  # https://github.com/codecov/ruby-standard-2
  # Generate HTML and Cobertura reports which can be consumed by codecov uploader
  SimpleCov.formatters = SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::CoberturaFormatter
  ])
  SimpleCov.start do
    add_filter "/test/"
    add_filter "app.rb"
    add_filter "init.rb"
    add_filter "/config/"
  end
end

require 'minitest/unit'
MiniTest::Unit.autorun

require_relative "../lib/goo.rb"

class GooTest

  class Unit < MiniTest::Unit

    def before_suites
    end

    def after_suites
    end

    def _run_suites(suites, type)
      begin
        before_suites
        super(suites, type)
      ensure
        after_suites
      end
    end

    def _run_suite(suite, type)
      %[1,5,10,20]
      ret = []
      [1,5,10,20].each do |slice_size|
        puts "\nrunning test with slice_loading_size=#{slice_size}"
        Goo.slice_loading_size=slice_size
        begin
          suite.before_suite if suite.respond_to?(:before_suite)
          ret += super(suite, type)
        ensure
          suite.after_suite if suite.respond_to?(:after_suite)
        end
      end
      return ret
    end
  end

  MiniTest::Unit.runner = GooTest::Unit.new

  def self.configure_goo
    if not Goo.configure?
      Goo.configure do |conf|
        conf.add_redis_backend(host: "localhost")
        conf.add_namespace(:omv, RDF::Vocabulary.new("http://omv.org/ontology/"))
        conf.add_namespace(:skos, RDF::Vocabulary.new("http://www.w3.org/2004/02/skos/core#"))
        conf.add_namespace(:owl, RDF::Vocabulary.new("http://www.w3.org/2002/07/owl#"))
        conf.add_namespace(:rdfs, RDF::Vocabulary.new("http://www.w3.org/2000/01/rdf-schema#"))
        conf.add_namespace(:goo, RDF::Vocabulary.new("http://goo.org/default/"),default=true)
        conf.add_namespace(:metadata, RDF::Vocabulary.new("http://goo.org/metadata/"))
        conf.add_namespace(:foaf, RDF::Vocabulary.new("http://xmlns.com/foaf/0.1/"))
        conf.add_namespace(:rdf, RDF::Vocabulary.new("http://www.w3.org/1999/02/22-rdf-syntax-ns#"))
        conf.add_namespace(:tiger, RDF::Vocabulary.new("http://www.census.gov/tiger/2002/vocab#"))
        conf.add_namespace(:bioportal, RDF::Vocabulary.new("http://data.bioontology.org/"))
        conf.add_namespace(:nemo, RDF::Vocabulary.new("http://purl.bioontology.org/NEMO/ontology/NEMO_annotation_properties.owl#"))
        conf.add_sparql_backend(
          :main, 
          backend_name: "4store",
          query: "http://localhost:9000/sparql/",
          data: "http://localhost:9000/data/",
          update: "http://localhost:9000/update/",
          options: { rules: :NONE }
        )
        conf.add_search_backend(:main, service: "http://localhost:8983/solr/term_search_core1")
        conf.use_cache = false
      end
    end
  end

  def self.triples_for_subject(resource_id)
    rs = Goo.sparql_query_client.query("SELECT * WHERE { #{resource_id.to_ntriples} ?p ?o . }")
    count = 0
    rs.each_solution do |sol|
      count += 1
    end
    return count
  end

  def self.count_pattern(pattern)
    q = "SELECT * WHERE { #{pattern} }"
    rs = Goo.sparql_query_client.query(q)
    count = 0
    rs.each_solution do |sol|
      count += 1
    end
    return count
  end

end

