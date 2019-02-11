var intervalArray = [];

var cfg_name = getUrlQueryStringValue('cfg_name');
if(!cfg_name) {
	cfg_name = 'unspecified';
}
var json_url=cfg_name;
if (!json_url.match(/.json/) && !json_url.match(/.vtf/) && !json_url.match(/.cfg/)) {
	json_url += ".json";
}

// Load and display JSON
d3.xhr(json_url, 'application/json', function(error, data) {
var nodes = {};
var linx = [];

// Strip comments (or else JSON.parse() will fail)
var stripped_data = data.response.replace(/^#.*$/gm, "");
var graph = JSON.parse(stripped_data);

if(!graph) {
	var e=document.getElementById('errms');
	e.innerHTML = 'Failed to load cfg named: ' + json_url;
}

document.getElementById('filename').innerHTML = json_url;
document.getElementById('description').innerHTML = graph.description;

graph.edges.forEach(function(link) {
  if(link.from && link.to) {
    var from_name = link.from.split(':',2)[0];
    var to_name = link.to.split(':',2)[0];
    link.source = nodes[from_name] || (nodes[from_name] = {name: from_name});
    link.target = nodes[to_name] || (nodes[to_name] = {name: to_name});
    link.type = "std";
    if (link.id.match(/phix/i)) { link.type="phix"; }
    linx.push(link);
  }
});

graph.nodes.forEach(function(node) {
  var name = node.id;
  var gnode = nodes[name];
  if(gnode){
    gnode.type = node.type;
    gnode.cmd = node.cmd;
    gnode.description = node.description;
    gnode.comment = node.comment;
    gnode.filename = node.name;
  }
});

var width = window.innerWidth * .8;
var height = window.innerHeight * .8;

var force = d3.layout.force()
    .nodes(d3.values(nodes))
    .links(linx)
    .size([width, height])
    .linkDistance(60)
    .charge(-300)
    .on("tick", tick)
    .start();

var drag = force.drag()
    .on("dragstart", dragstart);

var svg = d3.select("#graph").append("svg")
    .attr("width", width)
    .attr("height", height);

// Per-type markers, as they don't inherit styles.
svg.append("defs").selectAll("marker")
    .data(["std", "dummy", "intermediate", "final", "phix"])
  .enter().append("marker")
    .attr("id", function(d) { return d; })
    .attr("viewBox", "0 -5 10 10")
    .attr("refX", 15)
    .attr("refY", -1.5)
    .attr("markerWidth", 6)
    .attr("markerHeight", 6)
    .attr("orient", "auto")
  .append("path")
    .attr("d", "M0,-5L10,0L0,5");

var path = svg.append("g").selectAll("path")
    .data(force.links())
  .enter().append("path")
    .attr("class", function(d) { return "link " + d.type; })
    .attr("marker-end", function(d) { return "url(#" + d.type + ")"; })
	.on("mousedown", function(d) { display_link(d); });


var circle = svg.append("g").selectAll("circle")
    .data(force.nodes())
  .enter().append("circle")
    .attr("r", function(d) { return (d.name.match(/tee/) ? 4 : 8); })
    .attr("class", function(d) { return "node " + d.type; })
	.attr("id",function(d) { return 'x'+d.name; })
	.on("mousedown", function(d) { display_node(d); }) 
	.on("dblclick", dblclick)
    .call(force.drag);

// var circle = svg.append("g").selectAll("cross")
//     .data(force.nodes())
//  .enter().append("circle")
//     .attr("r", function() { return (Math.floor(Math.random() * 6) + 5);})
//     .call(force.drag);

var text = svg.append("g").selectAll("text")
    .data(force.nodes())
  .enter().append("text")
    .attr("x", 8)
    .attr("y", ".31em")
    .text(function(d) { return d.name; });


window.setInterval(refresh_progress, 30000);

// Use elliptical arc path segments to doubly-encode directionality.
function tick() {
  path.attr("d", linkArc);
  circle.attr("transform", transform);
  text.attr("transform", transform);
}

function linkArc(d) {
  var dx = d.target.x - d.source.x,
      dy = d.target.y - d.source.y,
      dr = Math.sqrt(dx * dx + dy * dy);
  return "M" + d.source.x + "," + d.source.y + "A" + dr + "," + dr + " 0 0,1 " + d.target.x + "," + d.target.y;
}

function transform(d) {
  return "translate(" + d.x + "," + d.y + ")";
}

function reset_description() {
	d3.select('#edge_edit').style('display','none');
	d3.select('#node_exec').style('display','none');
	d3.select('#node_file').style('display','none');
	d3.select('#node_vt').style('display','none');
}

function display_node(d) {
	reset_description();
	d3.selectAll('#node_type').attr('value',d.type);
	d3.selectAll('#node_name').attr('value',d.name);
	d3.selectAll('#node_description').text(d.description);
	d3.selectAll('#node_comment').text(d.comment);

	switch (d.type) {
		case 'EXEC':
			d3.select('#node_exec').style('display','block');
			d3.selectAll('#node_cmd').text(d.cmd);
			break;
		case 'VTFILE':
			d3.select('#node_vt').style('display','block');
			d3.selectAll('#node_filename').attr('value',d.filename);
			d3.select('#vt_href').attr('href','edit.html?cfg_name='+d.filename);
			break;
		default:
			d3.select('#node_file').style('display','block');
			d3.selectAll('#node_filename').attr('value',d.filename);
			break;
	}
}

function display_link(d) {
	reset_description();
	d3.select('#edge_edit').style('display','block');
	d3.select('#edge_name').attr('value',d.id);
	d3.select('#edge_from').attr('value',d.from);
	d3.select('#edge_to').attr('value',d.to);
	d3.select('#edge_description').text(d.description);
	d3.select('#edge_comment').text(d.comment);
}

function refresh_progress() {
	// clear the intervals
	var i;
	for (i=0; i < intervalArray.length; i++) {
		clearInterval(intervalArray[i]);
	}

	// this is apparently the quickest and surest way to empty an array
	while (intervalArray.length > 0) { intervalArray.pop(); }

	d3.json("cgi-bin/getProgress", function(error, json) {
		if (error) return console.warn(error);
//		console.warn(json);
		var circles = force.nodes();
		circles.forEach(function(c) { 
//			console.warn(c.name);
			if (typeof(json[c.name]) != 'undefined') {
				var job_status = json[c.name];
				if (job_status == 2) {
					// job currently running
					i = setInterval( function() {
						d3.select('#x'+c.name).style('stroke','#000').style('stroke-width','1px')
							.transition().style('stroke','green')
							.each('end',function() {
								d3.select(this)
									.transition().style('stroke-width','4px')
							})
					}, 2000);
					intervalArray.push(i);
				}
				if (job_status == 0) {
					// job has completed
					d3.select('#x'+c.name).transition().style('stroke','green').each('end',function() { 
						d3.select(this).transition().style('stroke-width','4px')
					});
				}
				if (job_status == 1) {
					// job waating on input or output pipe
					i = setInterval( function() {
						d3.select('#x'+c.name).style('stroke','#000').style('stroke-width','1px')
							.transition().style('stroke','red')
							.each('end',function() {
								d3.select(this)
									.transition().style('stroke-width','4px')
							})
					}, 2000);
					intervalArray.push(i);
				}

			} else {
				// job has not yet started
				d3.select('#x'+c.name).transition().style('stroke','black').each('end',function() {
					d3.select(this).transition().style('stroke-width','1px')
				});
			}
		});
	});
}

});

function getUrlQueryStringValue(name) {
	var cfg_name = '';
	var query = location.search.substring(1);

	var pairs = query.split('&');

	for(var i = 0; i < pairs.length; i++) {
		var pos = pairs[i].indexOf('=');
		if((pos == -1) || (pairs[i].substring(0,pos) !== 'cfg_name')) {
			continue;
		}

		cfg_name = pairs[i].substring(pos+1);
		break;
	}

	return cfg_name;
}

function dblclick(d) {
  d3.select(this).classed("fixed", d.fixed = false);
}

function dragstart(d) {
  d3.select(this).classed("fixed", d.fixed = true);
}


