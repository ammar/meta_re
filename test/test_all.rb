%w{ meta_re aliases }.each do |file|                                                                                                                                                                                       
  require File.expand_path("../test_#{file}", __FILE__)                                                                                                                                                                            
end 
