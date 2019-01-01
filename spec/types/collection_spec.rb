# frozen_string_literal: true

require File.join(File.dirname(__FILE__), '..', 'spec_helper.rb')

describe Attributor::Collection do
  subject(:type) { Attributor::Collection }

  context '.of' do
    [Attributor::Integer, Attributor::Struct].each do |member_type|
      it "returns an anonymous class with correct member_attribute of type #{member_type}" do
        klass = type.of(member_type)
        expect(klass).to be_a(::Class)
        expect(klass.member_type).to eq member_type
      end
    end

    [
      # FIXME: https://github.com/rightscale/attributor/issues/24
      #::Integer,
      #::String,
      #::Object
    ].each do |member_type|
      it "raises when given invalid element type #{member_type}" do
        expect { type.of(member_type) }.to raise_error(Attributor::AttributorException)
      end
    end
  end

  context '.construct' do
    # context 'with a Model (or Struct) member_type' do
    #   let(:member_type) { Attributor::Struct }

    #   it 'calls construct on that type' do
    #     member_type.should_receive(:construct).and_call_original

    #     Attributor::Collection.of(member_type)
    #   end

    # end

    # context 'with a non-Model (or Struct) member_type' do
    #   let(:member_type) { Attributor::Integer }

    #   it 'does not call construct on that type' do
    #     member_type.should_receive(:respond_to?).with(:construct).and_return(false)
    #     member_type.should_not_receive(:construct)

    #     Attributor::Collection.of(member_type)
    #   end

    # end

    context 'with :member_options option' do
      let(:element_options) { { identity: 'name' } }
    end
  end

  context '.native_type' do
    it 'returns Array' do
      expect(type.native_type).to be(type)
    end
  end

  context '.decode_json' do
    context 'for valid JSON strings' do
      [
        '[]',
        '[1,2,3]',
        '["alpha", "omega", "gamma"]',
        '["alpha", 2, 3.0]'
      ].each do |value|
        it "parses JSON string as array when incoming value is #{value.inspect}" do
          expect(type.decode_json(value)).to eq JSON.parse(value)
        end
      end
    end

    context 'for invalid JSON strings' do
      [
        'foobar',
        '2',
        '',
        2,
        nil
      ].each do |value|
        it "parses JSON string as array when incoming value is #{value.inspect}" do
          expect do
            type.decode_json(value)
          end.to raise_error(Attributor::AttributorException)
        end
      end
    end
  end

  context '.load' do
    context 'from a Set' do
      let(:values) { [1, 2, 3] }
      let(:value) { Set.new(values) }
      it 'loads properly' do
        expect(type.load(value)).to match_array values
      end
    end

    context 'with unspecified element type' do
      context 'for nil values' do
        it 'returns nil' do
          expect(type.load(nil)).to be nil
        end
      end

      context 'for valid values' do
        [
          [],
          [1, 2, 3],
          [Object.new, [1, 2], nil, true]
        ].each do |value|
          it "returns value when incoming value is #{value.inspect}" do
            expect(type.load(value)).to match_array value
          end
        end
      end

      context 'for invalid values' do
        let(:context) { %w[root subattr] }
        [1, Object.new, false, true, 3.0].each do |value|
          it "raises error when incoming value is #{value.inspect} (propagating the context)" do
            expect { expect(type.load(value, context)).to eq value }.to raise_error(Attributor::IncompatibleTypeError, /#{context.join('.')}/)
          end
        end
      end
    end

    context 'with Attributor::Type element type' do
      context 'for valid values' do
        {
          Attributor::String => %w[foo bar],
          Attributor::Integer => [1, '2', 3],
          Attributor::Float => [1.0, '2.0', Math::PI, Math::E],
          Attributor::DateTime => ['2001-02-03T04:05:06+07:00', 'Sat, 3 Feb 2001 04:05:06 +0700'],
          ::Chicken => [::Chicken.new, ::Chicken.new]
        }.each do |member_type, value|
          it "returns loaded value when member_type is #{member_type} and value is #{value.inspect}" do
            expected_result = value.map { |v| member_type.load(v) }
            expect(type.of(member_type).load(value)).to match_array expected_result
          end
        end
      end

      context 'for invalid values' do
        let(:member_type) { ::Chicken }
        let(:value) { [::Turducken.example] }
        it 'raises error when incoming value is not of member_type' do
          expect do
            type.of(member_type).load(value)
          end.to raise_error(Attributor::AttributorException, /Unknown key received/)
        end
      end
    end

    context 'with Attributor::Struct element type' do
      # FIXME: Raise in all cases of empty Structs
      # context 'for empty structs' do
      #   let(:attribute_definition) do
      #     Proc.new do
      #     end
      #   end

      #   let(:empty_struct) { Attributor::Struct.construct(attribute_definition) }

      #   # FIXME: these values are only valid because they aren't values at all.
      #   #        which isn't so bad, since a straight Struct can't have any values.
      #   #        so I suppose this is all correct, but not entirely valuable or obvious.
      #   context 'for valid struct values' do
      #     [
      #       [],
      #       [nil],
      #       [nil, nil],
      #       [{}],
      #       ["{}", "{}"],
      #     ].each do |value|
      #       it "returns value when incoming value is #{value.inspect}" do
      #         #pending
      #         expected_value = value.map {|v| empty_struct.load(v)}
      #         type.of(Struct).load(value).should eq expected_value
      #       end
      #     end
      #   end

      #   context 'for invalid struct values' do
      #     [
      #       [{"name" => "value"}, {"foo" => "another_value"}], # Ruby hash
      #       ['{"bar":"value"}'], # JSON hash
      #     ].each do |value|
      #       it "raises when incoming value is #{value.inspect}" do
      #         expect {
      #           type.of(empty_struct).load(value)
      #         }.to raise_error(Attributor::AttributorException)
      #       end
      #     end
      #   end

      # end

      context 'for simple structs' do
        let(:attribute_definition) do
          proc do
            attribute :name, Attributor::String
          end
        end

        let(:simple_struct) { Attributor::Struct.construct(attribute_definition) }

        context 'for valid struct values' do
          [
            [{ 'name' => 'value' }, { 'name' => 'another_value' }], # Ruby hash
            ['{"name":"value"}'], # JSON hash
          ].each do |value|
            it "returns value when incoming value is #{value.inspect}" do
              expected_value = value.map { |v| simple_struct.load(v.clone) }
              expect(type.of(simple_struct).load(value)).to match_array expected_value
            end
          end
        end

        context 'for invalid struct values' do
          [
            [{ 'name' => 'value' }, { 'foo' => 'another_value' }], # Ruby hash
            ['{"bar":"value"}'], # JSON hash
            [1, 2]
          ].each do |value|
            it "raises when incoming value is #{value.inspect}" do
              expect do
                type.of(simple_struct).load(value)
              end.to raise_error(Attributor::AttributorException)
            end
          end
        end
      end
    end
  end

  context '.validate' do
    context 'compatible type values' do
      let(:collection_members) { [1, 2, 'three'] }
      let(:expected_errors) { ['error 1', 'error 2', 'error 3'] }

      let(:value) { type.load(collection_members) }

      before do
        collection_members.zip(expected_errors).each do |member, expected_error|
          expect(type.member_attribute).to receive(:validate)
            .with(member, an_instance_of(Array)) # we don't care about the exact context here
            .and_return([expected_error])
        end
      end

      it 'validates members' do
        expect(type.validate(value)).to match_array expected_errors
      end
    end
    context 'invalid incoming types' do
      subject(:type) { Attributor::Collection.of(Integer) }
      it 'raise an exception' do
        expect do
          type.validate('invalid_value')
        end.to raise_error(ArgumentError, /can not validate object of type String/)
      end
    end
  end

  context '.example' do
    it 'returns an instance of the type' do
      value = type.example
      expect(value).to be_a(type)
    end

    [
      Attributor::Integer,
      Attributor::String,
      Attributor::Boolean,
      Attributor::DateTime,
      Attributor::Float,
      Attributor::Object
    ].each do |member_type|
      it "returns an Array of native types of #{member_type}" do
        value = Attributor::Collection.of(member_type).example
        expect(value).not_to be_empty
        expect(value.all? { |element| member_type.valid_type?(element) }).to be_truthy
      end
    end

    it 'returns an Array with size specified' do
      expect(type.example(options: { size: 5 }).size).to eq(5)
    end

    it 'returns an Array with size within a range' do
      5.times do
        expect(type.example(options: { size: (2..4) }).size).to be_within(1).of(3)
      end
    end

    context 'passing a non array context' do
      it 'still is handled correctly ' do
        expect do
          type.example('SimpleString')
        end.to_not raise_error
      end
    end
  end

  context '.describe' do
    let(:type) { Attributor::Collection.of(Attributor::String) }
    let(:example) { nil }
    subject(:described) { type.describe(example: example) }
    it 'includes the member_attribute' do
      expect(described).to have_key(:member_attribute)
      expect(described).not_to have_key(:example)
      expect(described[:member_attribute]).not_to have_key(:example)
    end

    context 'with an example' do
      let(:example) { type.example }
      it 'includes the member_attribute with an example from the first member' do
        expect(described).to have_key(:member_attribute)
        expect(described[:member_attribute]).to have_key(:example)
        expect(described[:member_attribute]).to eq(type.member_attribute.describe(example: example.first))
      end
      it 'includes the incoming example for the whole collection as well' do
        expect(described).to have_key(:example)
        expect(described[:example]).to eq(example)
      end
    end
  end

  context 'dumping' do
    let(:type) { Attributor::Collection.of(Cormorant) }

    it 'it is Dumpable' do
      expect(type.new.is_a?(Attributor::Dumpable)).to be(true)
    end

    subject(:example) { type.example }
    it 'dumps' do
      expect do
        example.dump
      end.to_not raise_error
    end
  end
end
