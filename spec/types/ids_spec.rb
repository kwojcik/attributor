# frozen_string_literal: true

require File.join(File.dirname(__FILE__), '..', 'spec_helper.rb')

describe Attributor::Ids do
  context '.for' do
    let(:chickens) { Array.new(10) { Chicken.example } }

    let(:emails) { chickens.collect(&:email) }
    let(:value) { emails.join(',') }

    subject!(:ids) { Attributor::Ids.for(Chicken) }

    its(:member_attribute) { should be(Chicken.attributes[:email]) }

    it 'loads' do
      expect(ids.load(value)).to match_array emails
    end

    it 'generates valid, loadable examples' do
      expect(ids.validate(ids.load(ids.example))).to be_empty
    end
  end

  context 'attempting to define it as a collection using .of(type)' do
    it 'raises an error' do
      expect do
        Attributor::Ids.of(Chicken)
      end.to raise_error(/Defining Ids.of\(type\) is not allowed/)
    end
  end
end
