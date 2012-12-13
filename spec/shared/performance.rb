shared_examples_for "performance" do

    describe "performance", :perf => true do

        it "should create and retrieve lots of nodes in a reasonable amount of time" do

            path = "/zkruby/rspec-perf"
            op = nil
            start = Time.now
            count = 0
            pass_every = 10
            first_error = true
            6000.times do
                count += 1
                this_index = count
                op = @zk.create("#{path}/","hello", ZK::ACL_OPEN_UNSAFE,:sequential,:ephemeral) { } 
                op.on_error { |ex| puts "Error @ #{this_index}" if first_error; first_error = false }
                if count % pass_every == 0
                    #puts "Passing @ #{count}"
                    ZK.pass
                end
            end

            op.value
            finish = Time.now
            diff = finish - start
            puts "Created #{count} in #{diff}" 
            stat,children = @zk.children(path)

            count = 0
            children.each do |child|
                op = @zk.get("#{path}/#{child}") { }
                count += 1
                if count % pass_every == 0
                    #puts "Passing @ #{count}"
                    ZK.pass
                end
            end

            op.value
            finish_get = Time.now
            diff = finish_get - finish
            puts "Retrieved #{count} in #{diff}"
        end

    end
end