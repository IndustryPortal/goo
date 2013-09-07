require_relative 'test_case'

GooTest.configure_goo

require_relative 'models'

class TestCache < MiniTest::Unit::TestCase

  def initialize(*args)
    super(*args)
  end

  def self.before_suite
    begin
      Goo.use_cache=false
      GooTestData.create_test_case_data
      redis = Goo.redis_client
      redis.smembers(SPARQL::Client::SPARQL_CACHE_QUERIES).each do |q|
        redis.del(q)
      end
      redis.smembers(SPARQL::Client::SPARQL_CACHE_GRAPHS).each do |g|
        redis.del(g)
      end
    rescue Exception => e
      puts e.backtrace
      binding.pry
    end
  end

  def self.after_suite
    GooTestData.delete_test_case_data
  end

  def test_cache_models
    redis = Goo.redis_client
    assert !Goo.use_cache?
    Goo.use_cache=true
    assert Goo.use_cache?
    programs = Program.where(name: "BioInformatics", university: [ name: "Stanford"  ]).all
    assert programs.length == 1
    assert programs.first.id.to_s["Stanford/BioInformatics"]
    assert redis.exists("sparql:graph:http://goo.org/default/Program")
    queries = redis.smembers(SPARQL::Client::SPARQL_CACHE_QUERIES)
    count = 0
    key = nil
    queries.each do |q|
      if q["Program"]
        count += 1
        key = q
      end
    end
    assert count == 1
    assert !key.nil?
    assert redis.exists(key)
    assert redis.sismember(SPARQL::Client::SPARQL_CACHE_QUERIES,key)

    
    prg = programs.first
    prg.bring_remaining
    prg.credits = 999
    prg.save

    #invalidated ?
    assert !redis.exists(key)
    assert !redis.sismember(SPARQL::Client::SPARQL_CACHE_QUERIES,key)
    programs = Program.where(name: "BioInformatics", university: [ name: "Stanford"  ]).all
    assert programs.length == 1
    prg = programs.first
    prg.bring_remaining

    #change comes back ?
    assert prg.credits == 999
  end

  def test_cache_models_back_door
    redis = Goo.redis_client
    assert !Goo.use_cache?
    Goo.use_cache=true
    assert Goo.use_cache?
    programs = Program.where(name: "BioInformatics", university: [ name: "Stanford"  ])
                          .include(:students).all
    assert programs.length == 1
    key = nil
    queries = redis.smembers(SPARQL::Client::SPARQL_CACHE_QUERIES)
    count = 0
    queries.each do |q|
      if q["Program"]
        count += 1
        key = q
      end
    end
    assert count == 1
    assert !key.nil?
    assert redis.exists(key)
    assert redis.sismember(SPARQL::Client::SPARQL_CACHE_QUERIES,key)

    prg = programs.first
    assert prg.students.length == 2
    prg.students.each do |st|
      st.bring(:name)
    end
    assert prg.students.map { |x| x.name }.sort == ["Daniel","Susan"]

    data = "<http://goo.org/default/student/Tim> " +
           "<http://goo.org/default/enrolled> " +
           "<http://example.org/program/Stanford/BioInformatics> ."
    
    Goo.sparql_data_client.append_triples(Student.type_uri,data,"application/x-turtle")
    programs = Program.where(name: "BioInformatics", university: [ name: "Stanford"  ])
                          .include(:students).all
    prg = programs.first
    assert prg.students.length == 3
    prg.students.each do |st|
      st.bring(:name)
    end
    assert prg.students.map { |x| x.name }.sort == ["Daniel","Susan","Tim"]
  end


end
