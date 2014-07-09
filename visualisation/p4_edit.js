
var cfg_name = getUrlQueryStringValue('cfg_name');
if(!cfg_name) {
	cfg_name = 'unspecified';
}

var json_url=cfg_name+".json";
var graph;

var nodes = {};
var links = [];
var lastNodeId = 0;

var path, circle, text, svg, force;

// mouse event vars
var selected_node = null,
    selected_link = null,
    mousedown_link = null,
    mousedown_node = null,
    mouseup_node = null;


var width = 1200;
var height = 1200;
var colors = d3.scale.category10();

// Load the JSON file
d3.json(json_url, function(error, data) {
if(!data) {
	var e=document.getElementById('errms');
	e.innerHTML = 'Failed to load file: '+cfg_name;
}
graph=data;
visualise();
restart();
});



function visualise() {
document.getElementById('filename').innerHTML = json_url;
document.getElementById('description').innerHTML = graph.description;


graph.edges.forEach(function(link) {
  var from_name = link.from.split(':',2)[0];
  var to_name = link.to.split(':',2)[0];
  link.source = nodes[from_name] || (nodes[from_name] = {name: from_name});
  link.target = nodes[to_name] || (nodes[to_name] = {name: to_name});
  link.type = "std";
  links.push(link);
});

graph.nodes.forEach(function(node) {
  var name = node.id;
  var gnode = nodes[name];
  if(gnode){
    gnode.type = node.type;
  }
});

svg = d3.select("#graph").append("svg")
    .attr("width", width)
    .attr("height", height)
.on('mousedown', mousedown)
  .on('mousemove', mousemove)
  .on('mouseup', mouseup);

force = d3.layout.force()
    .nodes(d3.values(nodes))
    .links(links)
    .size([width, height])
    .linkDistance(100)
    .charge(-500)
    .friction(0.9)
    .on("tick", tick)
    .start();


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

path = svg.append("g").selectAll("path")
    .data(force.links())
  .enter().append("path")
    .attr("class", function(d) { return "link " + d.type; })
    .attr("marker-end", function(d) { return "url(#" + d.type + ")"; });

circle = svg.append("g").selectAll("circle")
    .data(force.nodes())
  .enter().append("circle")
    .attr("r", 8)
    .attr("class", function(d) { return "node " + d.type; })
.on("dblclick", dblclick)
    .call(force.drag);

// var circle = svg.append("g").selectAll("cross")
//     .data(force.nodes())
//  .enter().append("circle")
//     .attr("r", function() { return (Math.floor(Math.random() * 6) + 5);})
//     .call(force.drag);

text = svg.append("g").selectAll("text")
    .data(force.nodes())
  .enter().append("text")
    .attr("x", 8)
    .attr("y", ".31em")
    .text(function(d) { return d.name; });
}

function resetMouseVars() {
  mousedown_node = null;
  mouseup_node = null;
  mousedown_link = null;
}


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


function mousedown() {
  // prevent I-bar on drag
  //d3.event.preventDefault();

  // because :active only works in WebKit?
  svg.classed('active', true);

  if(d3.event.ctrlKey || mousedown_node || mousedown_link) return;

  // insert new node at point
  var point = d3.mouse(this);
  var node = {id: ++lastNodeId, reflexive: false};
  node.x = point[0];
  node.y = point[1];
  nodes['node_'+lastNodeId] = node;

  restart();
}

function mousemove() {
  if(!mousedown_node) return;

  // update drag line
  drag_line.attr('d', 'M' + mousedown_node.x + ',' + mousedown_node.y + 'L' + d3.mouse(this)[0] + ',' + d3.mouse(this)[1]);

  restart();
}

function mouseup() {
  if(mousedown_node) {
    // hide drag line
    drag_line
      .classed('hidden', true)
      .style('marker-end', '');
  }

  // because :active only works in WebKit?
  svg.classed('active', false);

  // clear mouse event vars
  resetMouseVars();
}


function restart() {
return;
	var drag = force.drag().on("dragstart", dragstart);

  // path (link) group
  path = path.data(links);

  // update existing links
  path.classed('selected', function(d) { return d === selected_link; })
    .style('marker-start', function(d) { return d.left ? 'url(#start-arrow)' : ''; })
    .style('marker-end', function(d) { return d.right ? 'url(#end-arrow)' : ''; });


  // add new links
  path.enter().append('path')
    .attr('class', 'link')
    .classed('selected', function(d) { return d === selected_link; })
    .style('marker-start', function(d) { return d.left ? 'url(#start-arrow)' : ''; })
    .style('marker-end', function(d) { return d.right ? 'url(#end-arrow)' : ''; })
    .on('mousedown', function(d) {

      if(d3.event.ctrlKey) return;
      // select link
      mousedown_link = d;
      if(mousedown_link === selected_link) selected_link = null;
      else {
        selected_link = mousedown_link;
        d3.select('#edge_edit').style('display','block');
        d3.select('#node_edit').style('display','none');
      }
      selected_node = null;
      restart();
    });

  // remove old links
  path.exit().remove();

  // circle (node) group
  // NB: the function arg is crucial here! nodes are known by id, not by index!
  circle = circle.data(d3.values(nodes), function(d) { return d.name; });

  // update existing nodes (reflexive & selected visual states)
  circle.selectAll('circle')
    .style('fill', function(d) { return (d === selected_node) ? d3.rgb(colors(d.id)).brighter().toString() : colors(d.id); })
    .classed('reflexive', function(d) { return d.reflexive; });

  // add new nodes
  var g = circle.enter().append('g');

  g.append('circle')
    .attr('class', function(d) { return "node " + d.type; })
    .attr('r', 12)
    .style('fill', function(d) { return (d === selected_node) ? d3.rgb(colors(d.id)).brighter().toString() : colors(d.id); })
    .style('stroke', function(d) { return d3.rgb(colors(d.id)).darker().toString(); })
    .classed('reflexive', function(d) { return d.reflexive; })
    .call(force.drag);
    .on('mouseover', function(d) {
      if(!mousedown_node || d === mousedown_node) return;
      // enlarge target node
      d3.select(this).attr('transform', 'scale(1.1)');
    })
    .on('mouseout', function(d) {
      if(!mousedown_node || d === mousedown_node) return;
      // unenlarge target node
      d3.select(this).attr('transform', '');
    })
    .on('mousedown', function(d) {
      if(d3.event.ctrlKey) return;

      // select node
      mousedown_node = d;
      if(mousedown_node === selected_node) selected_node = null;
      else {
        selected_node = mousedown_node;
        d3.select('#node_edit').style('display','block');
        d3.select('#edge_edit').style('display','none');
      }
      selected_link = null;

      // reposition drag line
      drag_line
        .style('marker-end', 'url(#end-arrow)')
        .classed('hidden', false)
        .attr('d', 'M' + mousedown_node.x + ',' + mousedown_node.y + 'L' + mousedown_node.x + ',' + mousedown_node.y);

      restart();
    })
    .on('mouseup', function(d) {
      if(!mousedown_node) return;

      // needed by FF
      drag_line
        .classed('hidden', true)
        .style('marker-end', '');

      // check for drag-to-self
      mouseup_node = d;
      if(mouseup_node === mousedown_node) { resetMouseVars(); return; }

      // unenlarge target node
      d3.select(this).attr('transform', '');

      // add link to graph (update if exists)
      // NB: links are strictly source < target; arrows separately specified by booleans
      var source, target, direction;
      if(mousedown_node.id < mouseup_node.id) {
        source = mousedown_node;
        target = mouseup_node;
        direction = 'right';
      } else {
        source = mouseup_node;
        target = mousedown_node;
        direction = 'left';
      }

      var link;
      link = links.filter(function(l) {
        return (l.source === source && l.target === target);
      })[0];

      if(link) {
        link[direction] = true;
      } else {
        link = {source: source, target: target, left: false, right: false};
        link[direction] = true;
        links.push(link);
      }

      // select new link
      selected_link = link;
      selected_node = null;
      restart();
    });

  // show node IDs
  g.append('text')
      .attr('x', 0)
      .attr('y', 4)
      .text(function(d) { return d.name; });

  // remove old nodes
  circle.exit().remove();

  force.start();
}


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

