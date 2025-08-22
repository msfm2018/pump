cd ../ebin
mkdir logs
cd ../etc
set LogFile=\"../ebin/logs/gc.log\"
erl -name node1@127.0.0.1 -setcookie abc +K true   +P 1024000    -pa ../ebin -pa ../depsbin   -boot start_sasl -kernel error_logger {file,"%LogFile%"}  -sasl sasl_error_logger false  -s entry start  gc_gateway_app 