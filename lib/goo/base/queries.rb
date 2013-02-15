
module Goo
  module Queries

    class XsdTypeNotFoundForValue < StandardError
    end

    def self.value_to_rdf_object(value)
      raise StandardError, "hash not yet supported here" if value.kind_of? Hash

      xsd_type = SparqlRd::Utils::Xsd.xsd_type_from_value(value)
      raise XsdTypeNotFoundForValue, "XSD Type not found for value `#{value}` `#{value.class}`" \
        if xsd_type == nil
      SparqlRd::Utils::Xsd.xsd_string_from_value(value,xsd_type)
      xsd_type_string = SparqlRd::Utils::Xsd.types[xsd_type]
      return "\"\"\"#{value}\"\"\"^^<#{xsd_type_string}>"

    end

    def self.get_resource_class(id, store_name)
      resource_id = if id.kind_of? String then id else id.value end
      epr = Goo.store(store_name)
      q = <<eos
SELECT ?class WHERE { <#{resource_id}> a ?class }
LIMIT 1
eos
      rs = epr.query(q)
      model_class_uri = nil
      rs.each_solution do |sol|
        model_class_uri = sol.get(:class)
      end
      return nil if model_class_uri.nil?
      model = Goo.find_model_by_uri(model_class_uri.value)
      return model
    end

    def self.get_resource_attributes(resource_id, model_class, store_name, graph_id)
      if graph_id.nil?
        graph_id = Goo::Naming.get_graph_id(model_class)
      end
      if graph_id.kind_of? SparqlRd::Resultset::Node
        graph_id = graph_id.value
      end
      epr = Goo.store(store_name)
      graph = ""
      graph = " GRAPH <#{graph_id}> " unless resource_id.kind_of? SparqlRd::Resultset::BNode
      q = <<eos
SELECT DISTINCT * WHERE { #{graph} { #{resource_id.to_turtle} ?predicate ?object } }
eos
      rs = epr.query(q)
      attributes = Hash.new()
      rs.each_solution do |sol|
        pvalue = sol.get(:predicate).value
        attr_name = model_class.attr_for_predicate_uri(pvalue)
        if attr_name == :rdf_type
          next
        end
        if attr_name.nil?
          #TODO some means of proper warning here
          #puts "attr_name not found for #{pvalue}"
        else
          attributes[attr_name] = [] if attributes[attr_name].nil?
          object = sol.get(:object)
          if object.iri? or object.bnode?
            object_class = self.get_resource_class(object.value, store_name)
            if not object.nil? and not object_class.nil?
              object_instance = object_class.new
              object_instance.lazy_loaded
              object_instance.resource_id= object
              attributes[attr_name] << object_instance
            else
              attributes[attr_name] << RDF::IRI.new(object.value)
            end
          else
            attributes[attr_name] << object.parsed_value
          end
        end
      end
      return attributes
    end

    def self.model_to_triples(model,resource_id, expand_bnodes = false)
      expand_bnodes = (expand_bnodes and (model.loaded? or not model.persistent?))
      model_uri = model.class.type_uri
      if resource_id.iri? or (not expand_bnodes) or (not model.uuid.nil?)
        triples = [ "#{resource_id.to_turtle} <#{RDF.TYPE_IRI}> <#{model_uri}>" ]
      else
        triples = [ " <#{RDF.TYPE_IRI}> <#{model_uri}>" ]
      end

      #set defaults if needed
      model.class.goop_settings[:attributes].each_pair do |attr,conf|
        #we have a default on attr
        if model.class.goop_settings[:attributes][attr].include? :default
          default_proc = model.class.goop_settings[:attributes][attr][:default]
          #we do not have a value on attr
          unless model.attributes.include? attr
            model.attributes[attr] = default_proc.call(model)
          end
        end
      end

      model.attributes.each_pair do |name,value|
        if model.class.inverse_attr? name
          next
        end
        next if name == :internals
        subject = resource_id
        predicate = model.class.uri_for_predicate(name)
        values = (value.kind_of? Array and value or [value])
        values.each do |single_value|
          next if single_value.nil?
          if single_value.kind_of? Goo::Base::Resource
            object_iri = single_value.resource_id
            if object_iri.bnode? and expand_bnodes and
              (single_value.loaded? or not single_value.persistent?)
              bnode_tuples = model_to_triples(
                                single_value, object_iri, expand_bnodes)
              object = "[\n\t\t" << (bnode_tuples.join ";\n\t\t") << " ]"
            else
              object = object_iri.to_turtle
            end
          elsif single_value.kind_of? SparqlRd::Resultset::Node
            object = single_value.to_turtle
          else
            object = value_to_rdf_object(single_value)
          end
          if resource_id.iri? or (not expand_bnodes) or (not model.uuid.nil?)
            triples << "#{subject.to_turtle} <#{predicate}> #{object}"
          else
            triples << " <#{predicate}> #{object}"
          end
        end
      end
      return triples
    end

    def self.value_as_array(value)
        model_values = nil
        if value.kind_of? Array
          model_values = value
        else
          model_values = [value]
        end
        model_values
    end

    def self.recursively_collect_modified_models(model, models)
      model.attributes.each_pair do |name,value|
        (value_as_array value).each do |single_value|
          if single_value.kind_of? Goo::Base::Resource
            if single_value.modified?
              if not single_value.resource_id.bnode?
                models << single_value
              end
              recursively_collect_modified_models(single_value, models)
            end
          end
        end
      end
    end

    #TODO: delete only includes connected bnodes for the moment
    def self.build_sparql_delete_query(models)
        queries = []
        #TODO: dangerous. Model [0] is the master, the others are bnodes.
        models.each do |model|
          triples = model_to_triples(model,model.resource_id, expand_bnodes = false)
          graph_id =  model.class.collection(model) || Goo::Naming.get_graph_id(model.class)
          graph_id = graph_id.value if graph_id.kind_of? SparqlRd::Resultset::Node
          query = ["DELETE DATA { GRAPH <#{graph_id}> {"]
          triples.map! { |t| t + ' .' }
          query << triples
          query << "} }"
          queries << (query.join "\n")
        end
        return queries
    end

    def self.build_sparql_update_query(modified_models)
      queries = []
      triples = {}
      modified_models.each do |mmodel|
        graph_id = mmodel.class.collection(mmodel) || Goo::Naming.get_graph_id(mmodel.class)
        triples[graph_id] = [] unless triples.include? graph_id
        triples[graph_id].concat(model_to_triples(mmodel,mmodel.resource_id))
        mmodel.each_linked_base do |attr_name, umodel|
          next if umodel.persistent? and (not umodel.modified?)
          graph_id = mmodel.class.collection(umodel) || Goo::Naming.get_graph_id(umodel.class)
          triples[graph_id] = [] unless triples.include? graph_id
          if umodel.resource_id.bnode? and umodel.modified?
            triples[graph_id].concat(model_to_triples(umodel, umodel.resource_id))
          end
        end
      end
      triples.each_key do |gid|
        if triples[gid].length > 0
          query = ["INSERT DATA {"]
          query << " GRAPH <#{gid}> {"
          query << ((triples[gid].map { |t| t + " ."}).join "\n")
          query << "} }"
          queries << (query.join "\n")
        end
      end
      return queries
    end

    def self.count_backlinks(resource_id, store_name)
      epr = Goo.store(store_name)
      q = <<eos
SELECT (COUNT(?s) as ?c) WHERE {
  ?s ?p #{resource_id.to_turtle} .
}
eos
      rs = epr.query(q)
      rs.each_solution do |sol|
        return sol.get(:c).parsed_value
      end
      nil
    end
    def self.reachable_objects_from_recursive(resource_id, objects, store_name)
      epr = Goo.store(store_name)
      models = Goo.models
      q = <<eos
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
SELECT DISTINCT ?o WHERE {
  #{resource_id.to_turtle} ?p ?o .
  FILTER (!isLiteral(?o) && ?p != rdf:type) }
eos
      rs = epr.query(q)
      rs.each_solution do |sol|
        object = sol.get(:o)
        if not objects.include? object
          objects << object
        end
      end
    end

    def self.reachable_objects_from(resource_id, store_name,
                                    count_backlinks=false)
      reached_objects = Set.new
      reachable_objects_from_recursive(resource_id, reached_objects, store_name)
      filled_reached_objects = []
      reached_objects.each do |object|
        model_class = get_resource_class(object,store_name)
        if not model_class.nil?
          reached = { :id => object,
                      :model_class => model_class}
          if count_backlinks
            reached[:backlink_count] = self.count_backlinks(object,store_name)
          end
          filled_reached_objects << reached
        end
      end
      return filled_reached_objects
    end

    def self.get_resource_id_by_uuid(uuid, model_class, store_name)
      uuid_predicate = model_class.uri_for_predicate(:uuid)
      q = <<eos
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
SELECT ?res WHERE {
  ?res <#{uuid_predicate}> "#{uuid}"^^xsd:string
}
eos
      epr = Goo.store(store_name)
      res = epr.query(q)
      res.each_solution do |sol|
        return sol.get(:res)
      end
      return nil
    end

    def self.hash_to_triples_for_query(hash,model_class,subject_var)
      patterns = {}
      graph_id = Goo::Naming.get_graph_id(model_class)
      patterns[graph_id] = [] unless patterns.include? graph_id
      hash.each do |attr,v|
        predicate = model_class.uri_for_predicate(attr)
        [v].flatten.each do |value|
          if value.kind_of? Goo::Base::Resource
            rdf_object_string = value.resource_id.to_turtle
          elsif value.kind_of? Hash
            if model_class.attributes[attr][:validators].include? :instance_of
              model_symbol = model_class.attributes[attr][:validators][:instance_of][:with]
              model_att = Goo.find_model_by_name(model_symbol)
              if model_att.nil?
                raise ArgumentError, "Wrong configuration in instance_of makes nested search fail." +
                                     "`#{model_symbol}` has no associated model"
              end
              sub_patterns =  hash_to_triples_for_query(value,model_att,attr.to_s)
              sub_patterns.each_key do |graph_id|
                patterns[graph_id] = [] unless patterns.include? graph_id
                patterns[graph_id].concat(sub_patterns[graph_id])
              end
              rdf_object_string = "?#{attr.to_s}"
            else
              raise ArgumentError, "Nested search cannot be performed due to missing instance_of"
            end
          else
            rdf_object_string = value_to_rdf_object(value)
          end
          patterns[graph_id] << " ?#{subject_var} <#{predicate}> #{rdf_object_string} ."
        end
      end
      return patterns
    end

    def self.attributes_for_query(attrs,var,model_class,attribute_patterns)
        if attrs.kind_of? Array and attrs.length == 1 and attrs[0].kind_of? Hash
          attrs = attrs[0]
        end
        if attrs.kind_of? Array
          attr_hash = {}
          attrs.each do | v |
            attr_hash[v] = true
          end
          attrs = attr_hash
        end
        attrs = attrs.dup
        attrs.each_entry do |attr, nested|
          if (nested.kind_of? Hash or nested.kind_of? Array)
            optional = nested.delete :optional
          else
            optional = (nested == :optional)
          end
          if optional
            attribute_patterns << " OPTIONAL {"
          end
          predicate = model_class.uri_for_predicate(attr)
          attribute_patterns << " ?#{var} <#{predicate}> ?#{attr.to_s}_onmodel_#{model_class.goop_settings[:model].to_s} ."
          if (nested.kind_of? Hash or nested.kind_of? Array) and (nested.length > 0)
            #TODO
          end
          if optional
            attribute_patterns << "}"
          end
        end
    end

    #we need store name here
    def self.get_exist_query(model)
      graph_id = model.class.collection(model) || Goo::Naming.get_graph_id(model.class)
      return "SELECT * WHERE { GRAPH <#{graph_id}> { <#{model.resource_id.value}> a ?t .} } LIMIT 1 "
    end

    def self.search_by_attributes(attributes, model_class, store_name, ignore_inverse, load_attrs, only_known)
      #dictionary :named_graph => triple patterns
      patterns = {}
      graph_id = model_class.collection(nil,attributes) || Goo::Naming.get_graph_id(model_class)

      patterns[graph_id] = []
      patterns[graph_id] << " ?subject a <#{ model_class.type_uri}> ."

      if attributes.include? :resource_id
      end

      attributes.each do |attribute, value|
        next if model_class.collection_attribute? attribute
        if only_known && model_class.attributes[attribute.to_sym].nil?
         mess =  "Attribute `#{attribute}` is not declared in `#{model_class.name}`. " +\
                 "To enable search on unknown attributes use :only_known => false"
         raise ArgumentError, mess
        end
        predicate = nil
        inverse = false
        if not ignore_inverse and model_class.inverse_attr? attribute
          inv_cls, inv_attr = model_class.inverse_attr_options(attribute)
          predicate = inv_cls.uri_for_predicate(inv_attr)
          inverse = true
        else
          predicate = model_class.uri_for_predicate(attribute)
        end
        if value.kind_of? Goo::Base::Resource
          if inverse
            graph_id = Goo::Naming.get_graph_id(value.class)
            patterns[graph_id] = []
          end
          rdf_object_string = value.resource_id.to_turtle
        elsif value.kind_of? Hash
          if (!model_class.attributes[attribute].nil?) && (model_class.attributes[attribute][:validators].include? :instance_of)
            model_symbol = model_class.attributes[attribute][:validators][:instance_of][:with]
            model_att = Goo.find_model_by_name(model_symbol)
            if model_att.nil?
              raise ArgumentError, "Wrong configuration in instance_of makes nested search fail." +
                                   "`#{model_symbol}` has no associated model"
            end
            sub_patterns =  hash_to_triples_for_query(value,model_att,attribute.to_s)
            sub_patterns.each_key do |sub_graph_id|
              patterns[sub_graph_id] = [] unless patterns.include? sub_graph_id
              patterns[sub_graph_id].concat(sub_patterns[sub_graph_id])
            end
            rdf_object_string = "?#{attribute.to_s}"
          else
            raise ArgumentError, "Nested search cannot be performed due to missing instance_of in `#{attribute}`"
          end
        else
          rdf_object_string = value_to_rdf_object(value)
        end
        if not inverse
          patterns[graph_id] << " ?subject <#{predicate}> #{rdf_object_string} ."
        else
          patterns[graph_id] << " #{rdf_object_string} <#{predicate}> ?subject ."
        end
      end

      if load_attrs and load_attrs.length > 0
        attributes_patterns = []
        attributes_for_query(load_attrs,"subject",model_class, attributes_patterns)
        patterns[graph_id] << attributes_patterns
      end

      graph_patterns = []
      from_clauses = []
      patterns.each_key do |graph_id|
        from_clauses << "FROM <#{graph_id}>"
        graph_patterns << (patterns[graph_id].join "\n")
      end

      from_clauses = from_clauses.join "\n"
      patterns_string = graph_patterns.join "\n"
      query = <<eos
SELECT DISTINCT *
#{from_clauses}
WHERE {
    #{patterns_string}
} ORDER BY ?subject
eos
      return query
    end

  end
end
