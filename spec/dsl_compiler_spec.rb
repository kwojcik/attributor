# frozen_string_literal: true

require File.join(File.dirname(__FILE__), 'spec_helper.rb')

describe Attributor::DSLCompiler do
  let(:target) { double('model', attributes: {}) }

  let(:dsl_compiler_options) { {} }
  subject(:dsl_compiler) { Attributor::DSLCompiler.new(target, dsl_compiler_options) }

  let(:attribute_name) { :name }
  let(:type) { Attributor::String }

  let!(:reference_attributes) { Turducken.attributes }
  let(:reference_type) { reference_attribute.type }
  let(:reference_attribute_options) { reference_attribute.options }
  let(:reference_attribute) { reference_attributes[attribute_name] }

  context '#attribute' do
    let(:attribute_options) { {} }

    let(:expected_options) { attribute_options }
    let(:expected_type) { type }

    context 'when not not given a block for a sub-definition' do
      context 'without a reference' do
        it 'raises an error for a missing type' do
          expect do
            dsl_compiler.attribute(attribute_name)
          end.to raise_error(/type for attribute/)
        end

        it 'creates an attribute given a name and type' do
          expect(Attributor::Attribute).to receive(:new).with(expected_type, expected_options)
          dsl_compiler.attribute(attribute_name, type)
        end

        it 'creates an attribute given a name, type, and options' do
          expect(Attributor::Attribute).to receive(:new).with(expected_type, expected_options)
          dsl_compiler.attribute(attribute_name, type, attribute_options)
        end
      end

      context 'with a reference' do
        let(:dsl_compiler_options) { { reference: Turducken } }

        context 'with no options' do
          let(:expected_options) { reference_attribute_options }

          it 'creates an attribute with the inherited type' do
            expect(Attributor::Attribute).to receive(:new).with(expected_type, expected_options)
            dsl_compiler.attribute(attribute_name)
          end
        end

        context 'with options' do
          let(:attribute_options) { { description: 'some new description', required: true } }
          let(:expected_options) { reference_attribute_options.merge(attribute_options) }

          before do
            expect(Attributor::Attribute).to receive(:new).with(expected_type, expected_options)
          end

          it 'creates an attribute with the inherited type and merged options' do
            dsl_compiler.attribute(attribute_name, attribute_options)
          end

          it 'accepts explicit nil type' do
            dsl_compiler.attribute(attribute_name, nil, attribute_options)
          end

          context 'but with the attribute also specifying a reference' do
            let(:attribute_options) { { reference: Attributor::CSV } }
            let(:expected_type) { Attributor::CSV }
            let(:expected_options) { attribute_options }
            it 'attribute reference takes precedence over the compiler one (and merges no options)' do
              expect(attribute_options[:reference]).to_not eq(dsl_compiler_options[:reference])
              dsl_compiler.attribute(attribute_name, attribute_options)
            end
          end
        end

        context 'for a referenced Model attribute' do
          let(:attribute_name) { :turkey }
          let(:expected_type) { Turkey }
          let(:expected_options) { reference_attribute_options.merge(attribute_options) }

          it 'creates an attribute with the inherited type' do
            expect(Attributor::Attribute).to receive(:new).with(expected_type, expected_options)
            dsl_compiler.attribute(attribute_name)
          end
        end
      end
    end

    context 'when given a block for sub-attributes' do
      let(:attribute_block) { proc {} }
      let(:attribute_name) { :turkey }
      let(:type) { Attributor::Struct }
      let(:expected_type) { Attributor::Struct }

      context 'without a reference' do
        it 'defaults type to Struct' do
          expect(Attributor::Attribute).to receive(:new).with(expected_type, expected_options)
          dsl_compiler.attribute(attribute_name, &attribute_block)
        end
      end

      context 'with a reference' do
        let(:dsl_compiler_options) { { reference: Turducken } }
        let(:expected_options) do
          attribute_options.merge(reference: reference_type)
        end

        it 'sets the type of the attribute to Struct' do
          expect(Attributor::Attribute).to receive(:new)
            .with(expected_type, description: 'The turkey', reference: Turkey)
          dsl_compiler.attribute(attribute_name, attribute_options, &attribute_block)
        end

        it 'passes the correct reference to the created attribute' do
          expect(Attributor::Attribute).to receive(:new).with(expected_type, expected_options)
          dsl_compiler.attribute(attribute_name, type, attribute_options, &attribute_block)
        end
      end
    end
  end
end
