(function () {
  'use strict';
  function apply(product) {
    if (!product || !product.name) return;
    document.title = product.name;
    var name = document.getElementById('productName');
    if (name) name.textContent = product.name;
    var owner = document.getElementById('productOwner');
    if (owner && product.owner) owner.textContent = product.owner;
    var tag = document.getElementById('productTagline');
    if (tag && product.tagline) tag.textContent = product.tagline;
  }
  fetch('/api/product', { headers: { accept: 'application/json' } })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (data) { if (data && data.product) apply(data.product); })
    .catch(function () { /* the default title stays */ });
})();
