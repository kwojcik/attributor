# frozen_string_literal: true

module Attributor
  class InvalidDefinition < StandardError
    def initialize(type, cause)
      type_name = type.name || type.inspect

      msg = "Structure definition for type #{type_name} is invalid. The following exception has occurred: #{cause.inspect}"
      super(msg)
      @cause = cause
    end

    attr_reader :cause
  end

  class Hash
    MAX_EXAMPLE_DEPTH = 10
    CIRCULAR_REFERENCE_MARKER = '...'

    include Container
    include Enumerable
    include Dumpable

    class << self
      attr_reader :key_type, :value_type, :options
      attr_reader :value_attribute
      attr_reader :key_attribute
      attr_reader :insensitive_map
      attr_accessor :extra_keys
    end

    @key_type = Object
    @value_type = Object

    @key_attribute = Attribute.new(@key_type)
    @value_attribute = Attribute.new(@value_type)

    @error = false
    @requirements = []

    def self.key_type=(key_type)
      @key_type = Attributor.resolve_type(key_type)
      @key_attribute = Attribute.new(@key_type)
      @concrete = true
    end

    def self.value_type=(value_type)
      @value_type = Attributor.resolve_type(value_type)
      @value_attribute = Attribute.new(@value_type)
      @concrete = true
    end

    def self.family
      'hash'
    end

    @saved_blocks = []
    @options = { allow_extra: false }
    @keys = {}

    def self.inherited(klass)
      k = key_type
      v = value_type

      klass.instance_eval do
        @saved_blocks = []
        @options = { allow_extra: false }
        @keys = {}
        @key_type = k
        @value_type = v
        @key_attribute = Attribute.new(@key_type)
        @value_attribute = Attribute.new(@value_type)
        @requirements = []

        @error = false
      end
    end

    def self.attributes(**options, &key_spec)
      raise @error if @error

      keys(options, &key_spec)
    end

    def self.keys(**options, &key_spec)
      raise @error if @error

      if block_given?
        @saved_blocks << key_spec
        @options.merge!(options)
      elsif @saved_blocks.any?
        definition
      end
      @keys
    end

    def self.requirements
      definition if @saved_blocks.any?
      @requirements
    end

    def self.definition
      opts = {
        key_type: @key_type,
        value_type: @value_type
      }.merge(@options)

      blocks = @saved_blocks.shift(@saved_blocks.size)
      compiler = dsl_class.new(self, opts)
      compiler.parse(*blocks)

      if opts[:case_insensitive_load] == true
        @insensitive_map = keys.keys.each_with_object({}) do |k, map|
          map[k.downcase] = k
        end
      end
    rescue StandardError => e
      @error = InvalidDefinition.new(self, e)
      raise
    end

    def self.dsl_class
      @options[:dsl_compiler] || HashDSLCompiler
    end

    def self.native_type
      self
    end

    def self.valid_type?(type)
      type.is_a?(self) || type.is_a?(::Hash)
    end

    # @example Hash.of(key: String, value: Integer)
    def self.of(key: @key_type, value: @value_type)
      ::Class.new(self) do
        self.key_type = key
        self.value_type = value
        @keys = {}
      end
    end

    def self.constructable?
      true
    end

    def self.add_requirement(req)
      @requirements << req
      return unless req.attr_names

      non_existing = req.attr_names - attributes.keys

      return if non_existing.empty?

      raise "Invalid attribute name(s) found (#{non_existing.join(', ')}) when defining a requirement of type #{req.type} for #{Attributor.type_name(self)} ." \
          "The only existing attributes are #{attributes.keys}"
    end

    def self.construct(constructor_block, **options)
      return self if constructor_block.nil?

      unless @concrete
        return of(key: key_type, value: value_type)
               .construct(constructor_block, **options)
      end

      raise Attributor::AttributorException, ":case_insensitive_load may not be used with keys of type #{key_type.name}" if options[:case_insensitive_load] && !(key_type <= String)

      keys(options, &constructor_block)
      self
    end

    def self.example_contents(context, parent, **values)
      hash = ::Hash.new
      example_depth = context.size
      # Be smart about what attributes to use for the example: i.e. have into account complex requirements
      # that might have been defined in the hash like at_most(1).of ..., exactly(2).of ...etc.
      # But play it safe and default to the previous behavior in case there is any error processing them
      # ( that is until the SmartAttributeSelector class isn't fully tested and ready for prime time)
      begin
        stack = SmartAttributeSelector.new(requirements.map(&:describe), keys.keys, values)
        selected = stack.process
      rescue StandardError
        selected = keys.keys
      end

      keys.select { |n, _attr| selected.include? n }.each do |sub_attribute_name, sub_attribute|
        if sub_attribute.attributes
          # TODO: add option to raise an exception in this case?
          next if example_depth > MAX_EXAMPLE_DEPTH
        end

        sub_context = generate_subcontext(context, sub_attribute_name)
        block = proc do
          value = values.fetch(sub_attribute_name) do
            sub_attribute.example(sub_context, parent: parent)
          end
          sub_attribute.load(value, sub_context)
        end

        hash[sub_attribute_name] = block
      end

      hash
    end

    def self.example(context = nil, **values)
      return new if key_type == Object && value_type == Object && keys.empty?

      context ||= ["#{Hash}-#{rand(10_000_000)}"]
      context = Array(context)

      if keys.any?
        result = new
        result.extend(ExampleMixin)

        result.lazy_attributes = example_contents(context, result, values)
      else
        hash = ::Hash.new

        rand(1..3).times do |i|
          example_key = key_type.example(context + ["at(#{i})"])
          subcontext = context + ["at(#{example_key})"]
          hash[example_key] = value_type.example(subcontext)
        end

        result = new(hash)
      end

      result
    end

    def self.dump(value, **opts)
      loaded = load(value)
      loaded&.dump(**opts)
    end

    def self.check_option!(name, _definition)
      case name
      when :reference
        :ok # FIXME: ... actually do something smart
      when :dsl_compiler
        :ok
      when :case_insensitive_load
        raise Attributor::AttributorException, ":case_insensitive_load may not be used with keys of type #{key_type.name}" unless key_type <= String

        :ok
      when :allow_extra
        :ok
      else
        :unknown
      end
    end

    def self.load(value, context = Attributor::DEFAULT_ROOT_CONTEXT, recurse: false, **_options)
      context = Array(context)

      return value if value.is_a?(self)
      return nil if value.nil? && !recurse

      loaded_value = self.parse(value, context)

      return from_hash(loaded_value, context, recurse: recurse) if keys.any?

      load_generic(loaded_value, context)
    end

    def self.parse(value, context)
      if value.nil?
        {}
      elsif value.is_a?(Attributor::Hash)
        value.contents
      elsif value.is_a?(::Hash)
        value
      elsif value.is_a?(::String)
        decode_json(value, context)
      elsif value.respond_to?(:to_hash)
        value.to_hash
      else
        raise Attributor::IncompatibleTypeError, context: context, value_type: value.class, type: self
      end
    end

    def self.load_generic(value, context)
      return new(value) if key_type == Object && value_type == Object

      value.each_with_object(new) do |(k, v), obj|
        obj[key_type.load(k, context)] = value_type.load(v, context)
      end
    end

    def self.generate_subcontext(context, key_name)
      context + ["key(#{key_name.inspect})"]
    end

    def generate_subcontext(context, key_name)
      self.class.generate_subcontext(context, key_name)
    end

    def get(key, context: generate_subcontext(Attributor::DEFAULT_ROOT_CONTEXT, key))
      key = self.class.key_attribute.load(key, context)

      return self.get_generic(key, context) if self.class.keys.empty?

      value = @contents[key]

      # FIXME: getting an unset value here should not force it in the hash
      if (attribute = self.class.keys[key])
        loaded_value = attribute.load(value, context)
        return nil if loaded_value.nil?

        return self[key] = loaded_value
      end

      if self.class.options[:case_insensitive_load]
        key = self.class.insensitive_map[key.downcase]
        return get(key, context: context)
      end

      if self.class.options[:allow_extra]
        return @contents[key] = self.class.value_attribute.load(value, context) if self.class.extra_keys.nil?

        extra_keys_key = self.class.extra_keys

        return @contents[extra_keys_key].get(key, context: context) if @contents.key? extra_keys_key

      end

      raise LoadError, "Unknown key received: #{key.inspect} for #{Attributor.humanize_context(context)}"
    end

    def get_generic(key, context)
      if @contents.key? key
        value = @contents[key]
        loaded_value = value_attribute.load(value, context)
        return self[key] = loaded_value
      elsif self.class.options[:case_insensitive_load]
        key = key.downcase
        @contents.each do |k, _v|
          return get(key, context: context) if key == k.downcase
        end
      end
      nil
    end

    def set(key, value, context: generate_subcontext(Attributor::DEFAULT_ROOT_CONTEXT, key), recurse: false)
      key = self.class.key_attribute.load(key, context)

      return self[key] = self.class.value_attribute.load(value, context) if self.class.keys.empty?

      if (attribute = self.class.keys[key])
        return self[key] = attribute.load(value, context, recurse: recurse)
      end

      if self.class.options[:case_insensitive_load]
        key = self.class.insensitive_map[key.downcase]
        return set(key, value, context: context)
      end

      if self.class.options[:allow_extra]
        return self[key] = self.class.value_attribute.load(value, context) if self.class.extra_keys.nil?

        extra_keys_key = self.class.extra_keys

        unless @contents.key? extra_keys_key
          extra_keys_value = self.class.keys[extra_keys_key].load({})
          @contents[extra_keys_key] = extra_keys_value
        end

        return self[extra_keys_key].set(key, value, context: context)

      end

      raise LoadError, "Unknown key received: #{key.inspect} while loading #{Attributor.humanize_context(context)}"
    end

    def self.from_hash(object, context, recurse: false)
      hash = new

      # if the hash definition includes named extra keys, initialize
      # its value from the object in case it provides some already.
      # this is to ensure it exists when we handle any extra keys
      # that may exist in the object later
      if extra_keys
        sub_context = generate_subcontext(context, extra_keys)
        v = object.fetch(extra_keys, {})
        hash.set(extra_keys, v, context: sub_context, recurse: recurse)
      end

      object.each do |k, val|
        next if k == extra_keys

        sub_context = generate_subcontext(context, k)
        hash.set(k, val, context: sub_context, recurse: recurse)
      end

      # handle default values for missing keys
      keys.each do |key_name, attribute|
        next if hash.key?(key_name)

        sub_context = generate_subcontext(context, key_name)
        default = attribute.load(nil, sub_context, recurse: recurse)
        hash[key_name] = default unless default.nil?
      end

      hash
    end

    def self.validate(object, context = Attributor::DEFAULT_ROOT_CONTEXT, _attribute)
      context = [context] if context.is_a? ::String

      raise ArgumentError, "#{name} can not validate object of type #{object.class.name} for #{Attributor.humanize_context(context)}." unless object.is_a?(self)

      object.validate(context)
    end

    def self.describe(shallow = false, example: nil)
      hash = super(shallow)

      hash[:key] = { type: key_type.describe(true) } if key_type

      if keys.any?
        # Spit keys if it's the root or if it's an anonymous structures
        if !shallow || name.nil?
          required_names = []
          # FIXME: change to :keys when the praxis doc browser supports displaying those
          hash[:attributes] = keys.each_with_object({}) do |(sub_name, sub_attribute), sub_attributes|
            required_names << sub_name if sub_attribute.options[:required] == true
            sub_example = example.get(sub_name) if example
            sub_attributes[sub_name] = sub_attribute.describe(true, example: sub_example)
          end
          hash[:requirements] = requirements.each_with_object([]) do |req, list|
            described_req = req.describe(shallow)
            if described_req[:type] == :all
              # Add the names of the attributes that have the required flag too
              described_req[:attributes] |= required_names
              required_names = []
            end
            list << described_req
          end
          # Make sure we create an :all requirement, if there wasn't one so we can add the required: true attributes
          hash[:requirements] << { type: :all, attributes: required_names } unless required_names.empty?
        end
      else
        hash[:value] = { type: value_type.describe(true) }
        hash[:example] = example if example
      end

      hash
    end

    # TODO: Think about the format of the subcontexts to use: let's use .at(key.to_s)
    attr_reader :contents

    def [](k)
      @contents[k]
    end

    def _get_attr(k)
      self[k]
    end

    def []=(k, v)
      @contents[k] = v
    end

    def each(&block)
      @contents.each(&block)
    end

    alias each_pair each

    def size
      @contents.size
    end

    def keys
      @contents.keys
    end

    def values
      @contents.values
    end

    def empty?
      @contents.empty?
    end

    def key?(k)
      @contents.key?(k)
    end
    alias has_key? key?

    def merge(hash)
      case hash
      when self.class
        self.class.new(contents.merge(hash.contents))
      when Attributor::Hash
        raise ArgumentError, 'cannot merge Attributor::Hash instances of different types' unless hash.is_a?(self.class)
      else
        raise TypeError, "no implicit conversion of #{hash.class} into Attributor::Hash"
      end
    end

    def delete(key)
      @contents.delete(key)
    end

    attr_reader :validating, :dumping

    def initialize(contents = {})
      @validating = false
      @dumping = false

      @contents = contents
    end

    def key_type
      self.class.key_type
    end

    def value_type
      self.class.value_type
    end

    def key_attribute
      self.class.key_attribute
    end

    def value_attribute
      self.class.value_attribute
    end

    def ==(other)
      contents == other || (other.respond_to?(:contents) ? contents == other.contents : false)
    end

    def validate(context = Attributor::DEFAULT_ROOT_CONTEXT)
      context = [context] if context.is_a? ::String

      if self.class.keys.any?
        self.validate_keys(context)
      else
        self.validate_generic(context)
      end
    end

    def validate_keys(context)
      extra_keys = @contents.keys - self.class.keys.keys
      if extra_keys.any? && !self.class.options[:allow_extra]
        return extra_keys.collect do |k|
          "#{Attributor.humanize_context(context)} can not have key: #{k.inspect}"
        end
      end

      errors = []
      keys_with_values = []

      self.class.keys.each do |key, attribute|
        sub_context = self.class.generate_subcontext(context, key)

        value = @contents[key]
        keys_with_values << key unless value.nil?

        if value.respond_to?(:validating) # really, it's a thing with sub-attributes
          next if value.validating
        end

        errors.concat attribute.validate(value, sub_context)
      end
      self.class.requirements.each do |requirement|
        validation_errors = requirement.validate(keys_with_values, context)
        errors.concat(validation_errors) unless validation_errors.empty?
      end
      errors
    end

    def validate_generic(context)
      @contents.each_with_object([]) do |(key, value), errors|
        # FIXME: the sub contexts and error messages don't really make sense here
        unless key_type == Attributor::Object
          sub_context = context + ["key(#{key.inspect})"]
          errors.concat key_attribute.validate(key, sub_context)
        end

        unless value_type == Attributor::Object
          sub_context = context + ["value(#{value.inspect})"]
          errors.concat value_attribute.validate(value, sub_context)
        end
      end
    end

    def dump(**opts)
      return CIRCULAR_REFERENCE_MARKER if @dumping

      @dumping = true

      contents.each_with_object({}) do |(k, v), hash|
        k = key_attribute.dump(k, opts)

        v = if (attribute_for_value = self.class.keys[k])
              attribute_for_value.dump(v, opts)
            else
              value_attribute.dump(v, opts)
            end

        hash[k] = v
      end
    ensure
      @dumping = false
    end
  end
end
