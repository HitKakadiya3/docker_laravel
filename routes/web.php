<?php

use Illuminate\Support\Facades\Route;
use Inertia\Inertia;

// Health check route for deployment debugging
Route::get('/health', function () {
    return response('OK', 200)->header('Content-Type', 'text/plain');
});

Route::get('/', function () {
    return Inertia::render('Welcome');
})->name('home');

Route::get('dashboard', function () {
    return Inertia::render('Dashboard');
})->middleware(['auth', 'verified'])->name('dashboard');

require __DIR__.'/settings.php';
require __DIR__.'/auth.php';
