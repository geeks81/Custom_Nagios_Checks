angular.module('StreamsServices', ['ngResource'])
.factory('Streams',
  function($resource){
    return $resource('rpc/mpegtsmon', {}, {
      get: {method:'POST', params:{}}
  });
})
.factory('Probes',
  function($resource){
    return $resource('rpc/probes', {}, {
      get: {method:'POST', params:{}}
  });
});

function hex(i){
    return "0x"+i.toString(16);
}

angular.module('Filters', [])
.filter('mpegtsPid', function() {
  return function(input) {
    switch(input){
        case 0: return "PAT";
        case 1: return "CAT";
        case 2: return "TSDT";
        case 3: return "IPMP SIT";
        case 8191: return "Null";
    }
    if(input>=4 && input <=15) return "Rsrv"+ hex(input);
    if(input>=16 && input <=31) return "DVB"+hex(input);
    return hex(input);
  };
})
.filter('Kbps', function() {
  return function(input) {
    return Math.round(input*8/1024);
  };
})
.filter('autoPs', function() {
  return function(input) {
    var bps=input*8/1024;
    if(bps<1000)
        return Math.round(bps) +" Kbit/s";
    else
        return Math.round(10*bps/1024)/10 +" Mbit/s";
  };
})
.filter('badDetails', function() {
  return function(details) {
    return Object.keys(details)
    .filter(function(curr){
        return details[curr];
    })
    .reduce(function(akk, curr){
        return akk+curr+" ";
    },"");
  };
})
.filter('sortedKeys', function() {
  return function(obj) {
    if(undefined===obj) return;
    return Object.keys(obj).sort();
  };
})
.filter('sorted', function() {
  return function(arr) {
    return arr.sort();
  };
})
.filter('tagsList', function() {
  return function(arr) {
    if(undefined===arr) return "";
    return arr.sort().reduce(function(akk, curr){
        return akk+curr+" ";
    },"");
  };
})
;

angular.module('MpegtsMon', ['StreamsServices', 'Filters'])
  .controller('Streams',function($scope, Streams, Probes, $interval) {
    $scope.allNum=0;
    $scope.ratesLength=200;
    $scope.rates=new Object();
    $scope.totalRate={length:400, max:0, rates: new Array(), byte_ps:0};
    $scope.statuses=new Object();
    $scope.bads=new Array();
    $scope.showList=true;
    $scope.thumbs=new Array();
    $scope.params=new Object();
    $scope.showStreams=true;
    $scope.probes=new Array();
    $scope.probesStreams=new Object();
    $scope.probesRates=new Object();
    $scope.tagsShow = false;
    $scope.badSortPropertyName = 'addr';
    $scope.allSortPropertyName = 'addr';

    $scope.loadRates=function(){
        Streams.get({method:"rate_all"},function(data) {
            var totalRate=0;

            angular.forEach(data.result, function(stream, id){
                if(undefined===$scope.rates[id])
                    $scope.rates[id]={
                    max:0,
                    rates:new Array(),
                    discont:new Array(),
                    nullpid:new Array(),
                    bad:new Array()
                    };

                totalRate+=stream.byte_ps;

                push($scope.rates[id].rates, stream.byte_ps, $scope.ratesLength);
                $scope.rates[id].max=Math.max.apply(null, $scope.rates[id].rates);
                $scope.listAll[id].status.byte_ps=stream.byte_ps;

                push($scope.rates[id].discont, stream.discontinue_pi, $scope.ratesLength);
                push($scope.rates[id].nullpid, stream.nullpid_pi, $scope.ratesLength);

                push($scope.rates[id].bad, (undefined===$scope.statuses[id])?false:!$scope.statuses[id].is_ok, $scope.ratesLength);
            });

            $scope.totalRate.byte_ps = totalRate;
            push($scope.totalRate.rates, totalRate/10, $scope.totalRate.length);
            $scope.totalRate.max=Math.max.apply(null, $scope.totalRate.rates);
        });
    };

    $scope.loadStatuses=function(){
        Streams.get({method:"status_all"},function(data) {
            $scope.statuses = data.result;

            $scope.bads = Object.keys($scope.statuses).filter(function(curr){
                return  !$scope.statuses[curr].is_ok;
            });
        });
    };

    $scope.loadParams=function(){
        Streams.get({method:"params_all"},function(data) {
            $scope.params = data.result;
            angular.forEach(data.result, function(params){
                if(params["tags"] && params["tags"].length>0) $scope.tagsShow = true;
            });
        });
    };

    $scope.loadProbes=function(){
        Probes.get({method:"list"},function(data) {
            $scope.probes = data.result;
        });
    };

    $scope.loadProbesStreams=function(){
        Probes.get({method:"streams"},function(data) {
            $scope.probesStreams = data.result;

            angular.forEach(data.result, function(streams, probeId){
                if(undefined===$scope.probesRates[probeId])
                    $scope.probesRates[probeId] = new Object();

                angular.forEach($scope.listAll, function(stream, streamId){
                    if(undefined===$scope.probesRates[probeId][streamId])
                        $scope.probesRates[probeId][streamId] = {
                            discont:new Array(),
                            bad:new Array(),
                            last_discont:0
                        };

                    if(undefined===$scope.probesStreams[probeId][streamId]){
                        push($scope.probesRates[probeId][streamId].bad, "unknown", $scope.ratesLength);
                        push($scope.probesRates[probeId][streamId].discont, 0, $scope.ratesLength);
                    } else {
                    var stream = $scope.probesStreams[probeId][streamId];
                        push(
                            $scope.probesRates[probeId][streamId].discont,
                            stream.continuity_errors-$scope.probesRates[probeId][streamId].last_discont,
                            $scope.ratesLength);
                        $scope.probesRates[probeId][streamId].last_discont = stream.continuity_errors;

                        push($scope.probesRates[probeId][streamId].bad, stream.status, $scope.ratesLength);
                    }
                });
            });
        });
    };

    Streams.get({method:"list_all"},function(data) {
        $scope.listAll = data.result;
        $scope.allNum = Object.keys($scope.listAll).length;
        $scope.loadParams();
        $scope.loadStatuses();
        $scope.loadRates();
        $scope.loadProbes();

        $scope.thumbs=Object.keys($scope.listAll).map(function(id){
            return {id: id, name:"", src:thumbPath(id), show:false}
        });
    });

    $interval(function() {
        $scope.loadRates();
        $scope.loadProbesStreams();
    }, 10000);

    $interval(function() {
        $scope.loadStatuses();
        $scope.loadProbes();
    }, 29000);

    $interval(function() {
        angular.forEach($scope.thumbs, function(thumb){
            thumb.src=thumbPath(thumb.id+"?"+new Date().getTime());
        });
    }, 16000);

    $scope.d = function( arr, baseY){
        if(typeof arr === 'undefined') return "";
        if(typeof baseY === 'undefined') baseY=0;
            return arr.reduce(function(akk, curr, idx){
                      return akk+"M"+idx+" "+baseY+" V"+(baseY+curr)+" ";
               },"");
    }

    $scope.bad = function( arr, ampY){
        if(typeof arr === 'undefined') return "";
            return arr.reduce(function(akk, curr, idx){
                      if(curr) return akk+"M"+idx+" -"+ampY+" V"+(ampY)+" ";
                      else return akk+"M"+idx+" -"+ampY+" V -"+(ampY)+" ";
               },"");
    }

    $scope.streamStatus = function(probeId, streamId, mainIsOk){
        if(probeId in $scope.probesStreams && streamId in $scope.probesStreams[probeId]){
            if(mainIsOk && $scope.probesStreams[probeId][streamId].status=="up") return "none";
            else if(!mainIsOk && $scope.probesStreams[probeId][streamId].status=="down") return "none";
            return $scope.probesStreams[probeId][streamId].status;
         }
        else return "unknown";
    }

    $scope.badSortBy = function(propertyName) {
        $scope.badSortPropertyName = propertyName;
    };

    $scope.sortedBadIds = function() {
        if(undefined===$scope.bads) return;
        return $scope.sortedIds($scope.badSortPropertyName, $scope.bads)
    }

    $scope.allSortBy = function(propertyName) {
        $scope.allSortPropertyName = propertyName;
    };

    $scope.sortedAllIds = function() {
        if(undefined===$scope.listAll) return;
        return $scope.sortedIds($scope.allSortPropertyName, Object.keys($scope.listAll))
    }

    $scope.sortedIds = function(name, arr) {
      switch(name){
        case 'addr': return arr.sort();
        case 'name': return arr.sort($scope.sortIdByName);
        case 'tags': return arr.sort($scope.sortIdByTags);
        }
    }

    $scope.allSortBy = function(propertyName) {
        $scope.allSortPropertyName = propertyName;
    };

    $scope.sortIdByName = function(id0, id1) {
        var a = $scope.params[id0].name;
        var b = $scope.params[id1].name;
        return (a<b?-1:(a>b?1:0));
    }

    $scope.sortIdByTags = function(id0, id1) {
        if(undefined===$scope.params[id0].tags && undefined===$scope.params[id1].tags) return 0;
        if(undefined===$scope.params[id0].tags) return 1;
        if(undefined===$scope.params[id1].tags) return -1;
        var a = $scope.params[id0].tags.sort().join();
        var b = $scope.params[id1].tags.sort().join();
        return (a<b?-1:(a>b?1:0));
    }
  })
  .directive('vbox', function() {
     return function(scope, element, attrs) {
        scope.$watch(attrs.vbox, function(value) {
        	element.attr("viewBox", value);
        });
    };
  })
.directive('xhref', function() {
   return function(scope, element, attrs) {
      scope.$watch(attrs.xhref, function(value) {
        element.attr("xlink:href", value);
      });
  };
    });

// utils
function push(arr, value, maxLength){
    if(arr.length>=maxLength) arr.shift();
    arr.push(value);
}

function thumbPath(id){
    return "/esi/mpegtsmon_esi/thumb/"+id;
}